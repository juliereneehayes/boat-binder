module Billing
  class StripeTerminalReactivationSessionCreator
    SUPPORTED_TERMINAL_STATUS = "canceled"

    LocalEvidence = Struct.new(
      :subscription_id,
      :customer_id,
      :entitlement_ended_at,
      keyword_init: true
    )

    class ReactivationError < StandardError; end

    def self.call(account:, option_key:, success_url:, cancel_url:)
      new(account:, option_key:, success_url:, cancel_url:).call
    end

    def initialize(account:, option_key:, success_url:, cancel_url:, catalog: nil)
      @account = account
      @option_key = option_key.to_s
      @success_url = success_url
      @cancel_url = cancel_url
      @catalog = catalog
    end

    def call
      validate_account!
      validate_option!

      StripeAccountReconciliationLock.call(account_id: account.id) do
        evidence = local_evidence
        validate_canonical_subscription!(retrieve_subscription(evidence.subscription_id), evidence)

        StripeCheckoutSessionCreator.new(
          account:,
          option_key:,
          success_url:,
          cancel_url:,
          catalog:,
          replacement_subscription_id: evidence.subscription_id
        ).call
      end
    rescue ReactivationError
      raise
    rescue StripeCheckoutSessionCreator::CheckoutError,
      StripeWebhookAssociationError,
      StripeAccountReconciliationLock::LockTimeoutError => error
      log_failure(error)
      raise ReactivationError, "Stripe reactivation could not be started"
    rescue Stripe::StripeError => error
      log_failure(error)
      raise ReactivationError, "Stripe reactivation could not be started"
    end

    private

    attr_reader :account, :option_key, :success_url, :cancel_url

    def catalog
      @catalog ||= SubscriptionPlanCatalog.new
    end

    def validate_account!
      return if account&.persisted? && account.active? && account.account_type == "client"

      raise ReactivationError, "Verified terminal subscription evidence is unavailable"
    end

    def validate_option!
      option = catalog.find(option_key)
      return if option&.enabled? && option.plan_key == "self_managed"

      raise ReactivationError, "Subscription billing option is unavailable"
    end

    def local_evidence
      StripeAccountStateLock.call(account:) do |subscription, _attempt|
        valid = account.persisted? && account.active? && account.account_type == "client" &&
          subscription&.provider == Subscription::STRIPE_PROVIDER &&
          subscription.plan == "self_managed" &&
          subscription.status == "canceled" &&
          subscription.external_customer_id.present? &&
          subscription.external_subscription_id.present? &&
          subscription.last_synced_at.present? &&
          valid_historical_end?(subscription.entitlement_ended_at)
        raise ReactivationError, "Verified terminal subscription evidence is unavailable" unless valid

        LocalEvidence.new(
          subscription_id: subscription.external_subscription_id,
          customer_id: subscription.external_customer_id,
          entitlement_ended_at: subscription.entitlement_ended_at
        )
      end
    end

    def retrieve_subscription(subscription_id)
      Stripe::Subscription.retrieve(
        subscription_id,
        api_key: StripeConfiguration.secret_key!
      )
    end

    def validate_canonical_subscription!(remote_subscription, evidence)
      ended_at = timestamp(remote_subscription[:ended_at])
      option = canonical_option(remote_subscription)
      attempt = canonical_attempt(remote_subscription)

      valid = remote_subscription.id.to_s == evidence.subscription_id &&
        stripe_id(remote_subscription.customer) == evidence.customer_id &&
        remote_subscription.livemode == StripeConfiguration.expected_livemode! &&
        remote_subscription.status.to_s == SUPPORTED_TERMINAL_STATUS &&
        ended_at == evidence.entitlement_ended_at &&
        attempt.account_id == account.id &&
        attempt.status == "completed" &&
        attempt.stripe_customer_id == evidence.customer_id &&
        attempt.option_key == option.key
      raise ReactivationError, "Verified terminal subscription evidence is unavailable" unless valid

      StripeWebhookAccountReferenceValidator.call(
        reference: metadata(remote_subscription)[StripeCheckoutSessionCreator::ACCOUNT_REFERENCE_KEY].to_s,
        account_id: account.id
      )
    end

    def canonical_option(remote_subscription)
      price_ids = Array(remote_subscription.items&.data)
        .filter_map { |item| stripe_id(item.price).presence }
        .uniq
      raise ReactivationError, "Verified terminal subscription evidence is unavailable" unless price_ids.one?

      option = catalog.find_by_stripe_price_id(price_ids.first)
      remote_option_key = metadata(remote_subscription)[StripeCheckoutSessionCreator::OPTION_KEY].to_s
      valid = option&.plan_key == "self_managed" && option.key == remote_option_key
      return option if valid

      raise ReactivationError, "Verified terminal subscription evidence is unavailable"
    end

    def canonical_attempt(remote_subscription)
      reference = metadata(remote_subscription)[StripeCheckoutSessionCreator::ATTEMPT_REFERENCE_KEY].to_s
      StripeCheckoutAttemptReference.find!(reference)
    rescue StripeCheckoutAttemptReference::InvalidReferenceError
      raise ReactivationError, "Verified terminal subscription evidence is unavailable"
    end

    def valid_historical_end?(value)
      (value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)) && value <= Time.current
    end

    def timestamp(value)
      Time.at(Integer(value)).utc
    rescue ArgumentError, TypeError
      raise ReactivationError, "Verified terminal subscription evidence is unavailable"
    end

    def metadata(remote_subscription)
      remote_subscription.metadata || {}
    end

    def stripe_id(value)
      value.respond_to?(:id) ? value.id.to_s : value.to_s
    end

    def log_failure(error)
      Rails.logger.error("Stripe terminal reactivation failed error=#{error.class.name}")
    end
  end
end
