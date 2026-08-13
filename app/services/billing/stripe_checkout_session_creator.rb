module Billing
  class StripeCheckoutSessionCreator
    ACCOUNT_REFERENCE_KEY = "boat_binder_account"
    ATTEMPT_REFERENCE_KEY = "boat_binder_checkout_attempt"
    OPTION_KEY = "boat_binder_option"
    CHECKOUT_HOST = "checkout.stripe.com"
    MAX_ATTEMPT_TRANSITIONS = 6

    AttemptSnapshot = Struct.new(
      :id,
      :status,
      :option_key,
      :customer_id,
      :session_id,
      :idempotency_key,
      :signed_reference,
      keyword_init: true
    )
    Outcome = Struct.new(:session, :option_key, :attempt_id, :error, :expire_session_id, keyword_init: true)

    class CheckoutError < StandardError; end
    class InvalidAccountError < CheckoutError; end
    class InvalidOptionError < CheckoutError; end

    def self.call(account:, option_key:, success_url:, cancel_url:)
      new(
        account: account,
        option_key: option_key,
        success_url: success_url,
        cancel_url: cancel_url
      ).call
    end

    def initialize(account:, option_key:, success_url:, cancel_url:, catalog: nil)
      @account = account
      @option_key = option_key.to_s
      @success_url = success_url
      @cancel_url = cancel_url
      @catalog = catalog
    end

    def call
      option = selected_option
      customer_id = checkout_customer_id
      attempt_id = nil

      MAX_ATTEMPT_TRANSITIONS.times do
        attempt_id ||= reserve_attempt(option, customer_id)
        outcome = advance_attempt(attempt_id, option, customer_id)
        raise outcome.error if outcome.error
        return verified_session(outcome, option) if outcome.session

        attempt_id = outcome.attempt_id
      end

      raise CheckoutError, "Stripe Checkout attempt could not be stabilized"
    rescue CheckoutError
      raise
    rescue Stripe::StripeError => error
      Rails.logger.error(
        "Stripe Checkout creation failed option_key=#{option_key.inspect} error=#{error.class.name}"
      )
      raise CheckoutError, "Stripe Checkout could not be started"
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => error
      Rails.logger.error(
        "Stripe Checkout attempt persistence failed option_key=#{option_key.inspect} error=#{error.class.name}"
      )
      raise CheckoutError, "Stripe Checkout could not be started"
    end

    private

    attr_reader :account, :option_key, :success_url, :cancel_url

    def catalog
      @catalog ||= SubscriptionPlanCatalog.new
    end

    def selected_option
      option = catalog.find(option_key)
      return option if option&.enabled?

      raise InvalidOptionError, "Subscription billing option is unavailable"
    end

    def checkout_customer_id
      customer_id = StripeAccountStateLock.call(account: account) do |subscription, _attempt|
        if stripe_subscription_present?(subscription)
          complete_active_attempt!
          next InvalidAccountError.new("Account already has a Stripe subscription")
        end

        validate_subscription!(subscription)
        subscription.external_customer_id.presence || reusable_attempt_customer_id
      end
      raise customer_id if customer_id.is_a?(CheckoutError)

      customer_id || create_customer
    end

    def reusable_attempt_customer_id
      account.billing_checkout_attempts
        .where.not(stripe_customer_id: [ nil, "" ])
        .recent_first
        .pick(:stripe_customer_id)
    end

    def create_customer
      customer = Stripe::Customer.create(
        { metadata: { ACCOUNT_REFERENCE_KEY => account_reference } },
        {
          api_key: StripeConfiguration.secret_key!,
          idempotency_key: customer_idempotency_key
        }
      )
      customer_id = customer.id.to_s.presence
      return customer_id if customer_id

      raise CheckoutError, "Stripe Customer could not be created"
    end

    def reserve_attempt(option, customer_id)
      result = StripeAccountStateLock.call(account: account) do |subscription, _attempt|
        if stripe_subscription_present?(subscription)
          complete_active_attempt!
          next InvalidAccountError.new("Account already has a Stripe subscription")
        end

        validate_subscription!(subscription)
        ensure_customer_available!(customer_id)

        active_attempt = account.billing_checkout_attempts.active.lock.order(:id).first
        if active_attempt
          validate_attempt_customer!(active_attempt, customer_id)
          active_attempt.id
        else
          create_reserved_attempt(option, customer_id).id
        end
      end
      raise result if result.is_a?(CheckoutError)

      result
    end

    def create_reserved_attempt(option, customer_id)
      account.billing_checkout_attempts.create!(
        option_key: option.key,
        stripe_customer_id: customer_id,
        idempotency_key: SecureRandom.uuid,
        status: "creating"
      )
    end

    def advance_attempt(attempt_id, option, customer_id)
      snapshot = locked_attempt_snapshot(attempt_id, customer_id)
      return Outcome.new unless snapshot

      case snapshot.status
      when "creating"
        return option_mismatch_outcome unless snapshot.option_key == option.key

        activate_creating_attempt(snapshot)
      when "open", "replacing"
        inspect_checkout_session(snapshot, option, customer_id)
      when "submitted"
        Outcome.new(error: InvalidAccountError.new("Checkout completion is being synchronized"))
      else
        Outcome.new
      end
    end

    def locked_attempt_snapshot(attempt_id, customer_id)
      result = StripeAccountStateLock.call(account: account, attempt_id: attempt_id) do |subscription, attempt|
        if stripe_subscription_present?(subscription)
          attempt.update!(status: "completed") if attempt&.active?
          next InvalidAccountError.new("Account already has a Stripe subscription")
        end

        validate_subscription!(subscription)
        next unless attempt

        validate_attempt_customer!(attempt, customer_id)
        snapshot(attempt)
      end
      raise result if result.is_a?(CheckoutError)

      result
    end

    def activate_creating_attempt(snapshot)
      option = catalog.find(snapshot.option_key)
      unless option&.enabled?
        return Outcome.new(error: InvalidOptionError.new("Subscription billing option is unavailable"))
      end

      session = create_checkout_session(option, snapshot)
      return reject_incomplete_session(snapshot, session) unless session.id.present? && valid_checkout_url?(session.url)

      commit_result = commit_created_session(snapshot, session)
      return Outcome.new(session: session, option_key: snapshot.option_key) if commit_result == :committed
      if commit_result == :authoritative
        return Outcome.new(error: InvalidAccountError.new("Account already has a Stripe subscription"))
      end

      expire_checkout_session(session.id)
      close_uncommitted_attempt(snapshot, session.id)
      Outcome.new(error: InvalidAccountError.new("Account already has a Stripe subscription"))
    end

    def commit_created_session(snapshot, session)
      StripeAccountStateLock.call(account: account, attempt_id: snapshot.id) do |subscription, attempt|
        next :authoritative if attempt && %w[submitted completed].include?(attempt.status)
        if stripe_subscription_present?(subscription)
          attempt.update!(status: attempt.status == "creating" ? "canceled" : "completed") if attempt&.active?
          next :subscription_active
        end

        validate_subscription!(subscription)
        next :stale unless attempt

        case attempt.status
        when "creating"
          next :stale unless attempt_matches_snapshot?(attempt, snapshot)

          attempt.update!(stripe_checkout_session_id: session.id, status: "open")
          :committed
        when "open"
          attempt.stripe_checkout_session_id == session.id ? :committed : :stale
        when "submitted", "completed"
          :authoritative
        else
          :stale
        end
      end
    end

    def reject_incomplete_session(snapshot, session)
      expire_checkout_session(session.id) if session.id.present?
      close_uncommitted_attempt(snapshot, session.id)
      Outcome.new(error: CheckoutError.new("Stripe Checkout Session was incomplete"))
    end

    def close_uncommitted_attempt(snapshot, session_id)
      StripeAccountStateLock.call(account: account, attempt_id: snapshot.id) do |_subscription, attempt|
        next unless attempt
        next unless %w[creating open].include?(attempt.status)
        next if attempt.status == "open" && attempt.stripe_checkout_session_id != session_id

        attempt.update!(stripe_checkout_session_id: session_id, status: "canceled")
      end
    end

    def inspect_checkout_session(snapshot, option, customer_id)
      session = retrieve_checkout_session(snapshot.session_id)
      outcome = apply_retrieved_session(snapshot, session, option, customer_id)
      return outcome unless outcome.expire_session_id

      expired_session = expire_checkout_session(outcome.expire_session_id)
      unless expired_session.status == "expired"
        return Outcome.new(error: CheckoutError.new("Stripe Checkout Session could not be replaced"))
      end

      finish_replacement(snapshot, option, customer_id)
    end

    def apply_retrieved_session(snapshot, session, option, customer_id)
      StripeAccountStateLock.call(account: account, attempt_id: snapshot.id) do |subscription, attempt|
        validate_subscription!(subscription)
        next Outcome.new unless attempt

        validate_attempt_customer!(attempt, customer_id)
        next Outcome.new unless attempt.stripe_checkout_session_id == snapshot.session_id

        apply_session_status(attempt, session, option, customer_id)
      end
    end

    def apply_session_status(attempt, session, option, customer_id)
      case attempt.status
      when "open"
        apply_open_attempt_status(attempt, session, option, customer_id)
      when "replacing"
        apply_replacing_attempt_status(attempt, session, option, customer_id)
      when "submitted", "completed"
        Outcome.new(error: InvalidAccountError.new("Checkout completion is being synchronized"))
      else
        Outcome.new
      end
    end

    def apply_open_attempt_status(attempt, session, option, customer_id)
      case session.status
      when "open"
        if attempt.option_key == option.key && valid_checkout_url?(session.url)
          Outcome.new(session: session, option_key: attempt.option_key)
        else
          attempt.update!(status: "replacing")
          Outcome.new(expire_session_id: session.id)
        end
      when "complete"
        attempt.update!(status: "submitted")
        Outcome.new(error: InvalidAccountError.new("Checkout completion is being synchronized"))
      when "expired"
        attempt.update!(status: "expired")
        Outcome.new(attempt_id: create_reserved_attempt(option, customer_id).id)
      else
        Outcome.new(error: CheckoutError.new("Stripe Checkout Session status was unavailable"))
      end
    end

    def apply_replacing_attempt_status(attempt, session, option, customer_id)
      case session.status
      when "open"
        Outcome.new(expire_session_id: session.id)
      when "complete"
        attempt.update!(status: "submitted")
        Outcome.new(error: InvalidAccountError.new("Checkout completion is being synchronized"))
      when "expired"
        attempt.update!(status: "replaced")
        Outcome.new(attempt_id: create_reserved_attempt(option, customer_id).id)
      else
        Outcome.new(error: CheckoutError.new("Stripe Checkout Session status was unavailable"))
      end
    end

    def finish_replacement(snapshot, option, customer_id)
      StripeAccountStateLock.call(account: account, attempt_id: snapshot.id) do |subscription, attempt|
        validate_subscription!(subscription)
        next Outcome.new unless attempt

        validate_attempt_customer!(attempt, customer_id)
        if attempt.status == "replacing" && attempt.stripe_checkout_session_id == snapshot.session_id
          attempt.update!(status: "replaced")
          Outcome.new(attempt_id: create_reserved_attempt(option, customer_id).id)
        elsif %w[submitted completed].include?(attempt.status)
          Outcome.new(error: InvalidAccountError.new("Checkout completion is being synchronized"))
        else
          Outcome.new
        end
      end
    end

    def create_checkout_session(option, snapshot)
      subscription_data = { metadata: stripe_metadata(snapshot) }
      subscription_data[:trial_period_days] = option.trial_days if option.trial?

      Stripe::Checkout::Session.create(
        {
          mode: "subscription",
          customer: snapshot.customer_id,
          client_reference_id: account_reference,
          line_items: [ { price: option.stripe_price_id, quantity: 1 } ],
          payment_method_collection: "always",
          subscription_data: subscription_data,
          metadata: stripe_metadata(snapshot),
          success_url: success_url,
          cancel_url: cancel_url
        },
        {
          api_key: StripeConfiguration.secret_key!,
          idempotency_key: checkout_idempotency_key(snapshot)
        }
      )
    end

    def retrieve_checkout_session(session_id)
      raise CheckoutError, "Active Checkout Session is incomplete" if session_id.blank?

      Stripe::Checkout::Session.retrieve(session_id, api_key: StripeConfiguration.secret_key!)
    end

    def expire_checkout_session(session_id)
      Stripe::Checkout::Session.expire(
        session_id,
        {},
        { api_key: StripeConfiguration.secret_key! }
      )
    end

    def valid_checkout_url?(url)
      uri = URI.parse(url.to_s)
      uri.is_a?(URI::HTTPS) && uri.host == CHECKOUT_HOST
    rescue URI::InvalidURIError
      false
    end

    def validate_subscription!(subscription)
      raise InvalidAccountError, "Account subscription state is unavailable" unless subscription
      raise InvalidAccountError, "Account already has a Stripe subscription" if stripe_subscription_present?(subscription)
      return if subscription.external_customer_id.blank? || subscription.provider == Subscription::STRIPE_PROVIDER

      raise InvalidAccountError, "Account Stripe Customer association is invalid"
    end

    def stripe_subscription_present?(subscription)
      subscription&.external_subscription_id.present?
    end

    def complete_active_attempt!
      active_attempt = account.billing_checkout_attempts.active.lock.order(:id).first
      active_attempt&.update!(status: "completed")
    end

    def validate_attempt_customer!(attempt, customer_id)
      return if attempt.stripe_customer_id == customer_id

      raise InvalidAccountError, "Active Checkout Customer association is invalid"
    end

    def verified_session(outcome, option)
      return outcome.session if outcome.option_key == option.key

      raise InvalidOptionError, "Active Checkout attempt uses another billing option"
    end

    def option_mismatch_outcome
      Outcome.new(error: InvalidOptionError.new("Active Checkout attempt uses another billing option"))
    end

    def attempt_matches_snapshot?(attempt, snapshot)
      attempt.option_key == snapshot.option_key &&
        attempt.stripe_customer_id == snapshot.customer_id &&
        attempt.idempotency_key == snapshot.idempotency_key
    end

    def snapshot(attempt)
      AttemptSnapshot.new(
        id: attempt.id,
        status: attempt.status,
        option_key: attempt.option_key,
        customer_id: attempt.stripe_customer_id,
        session_id: attempt.stripe_checkout_session_id,
        idempotency_key: attempt.idempotency_key,
        signed_reference: StripeCheckoutAttemptReference.generate(attempt)
      )
    end

    def ensure_customer_available!(customer_id)
      subscription_conflict = Subscription
        .where(provider: Subscription::STRIPE_PROVIDER, external_customer_id: customer_id)
        .where.not(account_id: account.id)
        .exists?
      attempt_conflict = BillingCheckoutAttempt
        .where(stripe_customer_id: customer_id)
        .where.not(account_id: account.id)
        .exists?
      return unless subscription_conflict || attempt_conflict

      raise InvalidAccountError, "Stripe Customer is associated with another account"
    end

    def stripe_metadata(snapshot)
      {
        ACCOUNT_REFERENCE_KEY => account_reference,
        ATTEMPT_REFERENCE_KEY => snapshot.signed_reference,
        OPTION_KEY => snapshot.option_key
      }
    end

    def account_reference
      @account_reference ||= StripeAccountReference.generate(account)
    end

    def customer_idempotency_key
      "boat-binder-customer-v1-#{Digest::SHA256.hexdigest("account-#{account.id}")}"
    end

    def checkout_idempotency_key(snapshot)
      "boat-binder-checkout-v1-#{snapshot.idempotency_key}"
    end
  end
end
