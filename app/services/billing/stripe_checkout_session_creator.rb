module Billing
  class StripeCheckoutSessionCreator
    ACCOUNT_REFERENCE_KEY = "boat_binder_account"
    ATTEMPT_REFERENCE_KEY = "boat_binder_checkout_attempt"
    OPTION_KEY = "boat_binder_option"
    CHECKOUT_HOST = "checkout.stripe.com"
    MAX_ATTEMPT_TRANSITIONS = 3

    AttemptResult = Struct.new(:attempt, :session, :error, keyword_init: true)

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
      validate_subscription!(account.subscription)
      customer_id = reusable_customer_id || create_customer

      MAX_ATTEMPT_TRANSITIONS.times do
        reservation = reserve_attempt(option, customer_id)
        raise reservation.error if reservation.error
        return reservation.session if reservation.session

        activation = activate_attempt(reservation.attempt, option, customer_id)
        raise activation.error if activation.error
        return activation.session if activation.session && activation.attempt.option_key == option.key
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

    def validate_subscription!(subscription)
      raise InvalidAccountError, "Account subscription state is unavailable" unless subscription
      raise InvalidAccountError, "Account already has a Stripe subscription" if subscription.external_subscription_id.present?
      return if subscription.external_customer_id.blank? || subscription.provider == Subscription::STRIPE_PROVIDER

      raise InvalidAccountError, "Account Stripe Customer association is invalid"
    end

    def reusable_customer_id
      account.subscription.external_customer_id.presence ||
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
      account.with_lock do
        validate_subscription!(account.subscription.reload)
        ensure_customer_available!(customer_id)

        active_attempt = account.billing_checkout_attempts.active.first
        if active_attempt
          reserve_from_active_attempt(active_attempt, option, customer_id)
        else
          AttemptResult.new(attempt: create_reserved_attempt(option, customer_id))
        end
      end
    end

    def reserve_from_active_attempt(attempt, option, customer_id)
      unless attempt.stripe_customer_id == customer_id
        raise InvalidAccountError, "Active Checkout Customer association is invalid"
      end
      if attempt.status == "submitted"
        return AttemptResult.new(error: InvalidAccountError.new("Checkout completion is being synchronized"))
      end
      return AttemptResult.new(attempt: attempt) if attempt.status == "creating"

      session = retrieve_checkout_session(attempt)
      case session.status
      when "open"
        if attempt.option_key == option.key && valid_checkout_url?(session.url)
          AttemptResult.new(attempt: attempt, session: session)
        else
          expire_checkout_session(session.id)
          attempt.update!(status: "replaced")
          AttemptResult.new(attempt: create_reserved_attempt(option, customer_id))
        end
      when "complete"
        attempt.update!(status: "submitted")
        AttemptResult.new(error: InvalidAccountError.new("Checkout completion is being synchronized"))
      when "expired"
        attempt.update!(status: "expired")
        AttemptResult.new(attempt: create_reserved_attempt(option, customer_id))
      else
        AttemptResult.new(error: CheckoutError.new("Stripe Checkout Session status was unavailable"))
      end
    end

    def create_reserved_attempt(option, customer_id)
      account.billing_checkout_attempts.create!(
        option_key: option.key,
        stripe_customer_id: customer_id,
        idempotency_key: SecureRandom.uuid,
        status: "creating"
      )
    end

    def activate_attempt(attempt, option, customer_id)
      account.with_lock do
        attempt.reload
        case attempt.status
        when "creating"
          activate_creating_attempt(attempt)
        when "open"
          reserve_from_active_attempt(attempt, option, customer_id)
        when "submitted"
          AttemptResult.new(error: InvalidAccountError.new("Checkout completion is being synchronized"))
        else
          AttemptResult.new(error: CheckoutError.new("Checkout attempt is no longer active"))
        end
      end
    end

    def activate_creating_attempt(attempt)
      option = catalog.find(attempt.option_key)
      unless option&.enabled?
        return AttemptResult.new(error: InvalidOptionError.new("Subscription billing option is unavailable"))
      end

      session = create_checkout_session(option, attempt.stripe_customer_id, attempt)
      unless session.id.present? && valid_checkout_url?(session.url)
        expire_checkout_session(session.id) if session.id.present?
        attempt.update!(status: "canceled")
        return AttemptResult.new(error: CheckoutError.new("Stripe Checkout Session was incomplete"))
      end

      attempt.update!(stripe_checkout_session_id: session.id, status: "open")
      AttemptResult.new(attempt: attempt, session: session)
    end

    def create_checkout_session(option, customer_id, attempt)
      Stripe::Checkout::Session.create(
        {
          mode: "subscription",
          customer: customer_id,
          client_reference_id: account_reference,
          line_items: [ { price: option.stripe_price_id, quantity: 1 } ],
          payment_method_collection: "always",
          subscription_data: {
            trial_period_days: option.trial_days,
            metadata: stripe_metadata(attempt)
          },
          metadata: stripe_metadata(attempt),
          success_url: success_url,
          cancel_url: cancel_url
        },
        {
          api_key: StripeConfiguration.secret_key!,
          idempotency_key: checkout_idempotency_key(attempt)
        }
      )
    end

    def retrieve_checkout_session(attempt)
      session_id = attempt.stripe_checkout_session_id.presence
      raise CheckoutError, "Active Checkout Session is incomplete" unless session_id

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

    def stripe_metadata(attempt)
      {
        ACCOUNT_REFERENCE_KEY => account_reference,
        ATTEMPT_REFERENCE_KEY => StripeCheckoutAttemptReference.generate(attempt),
        OPTION_KEY => attempt.option_key
      }
    end

    def account_reference
      @account_reference ||= StripeAccountReference.generate(account)
    end

    def customer_idempotency_key
      "boat-binder-customer-v1-#{Digest::SHA256.hexdigest("account-#{account.id}")}"
    end

    def checkout_idempotency_key(attempt)
      "boat-binder-checkout-v1-#{attempt.idempotency_key}"
    end
  end
end
