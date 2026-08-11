module Billing
  class StripeCheckoutCompletionSynchronizer
    WEBHOOK_ELIGIBLE_ATTEMPT_STATUSES = %w[open submitted completed].freeze

    def self.call(checkout_session)
      new(checkout_session).call
    end

    def initialize(checkout_session)
      @checkout_session = checkout_session
    end

    def call
      validate_checkout_session!
      attempt = checkout_attempt

      attempt.with_lock do
        subscription = attempt.account.subscription
        raise_association_error("missing_local_subscription") unless subscription

        subscription.lock!
        validate_attempt!(attempt)
        validate_account_reference!(attempt.account_id)
        validate_identifiers!(subscription)
        subscription.update!(
          provider: Subscription::STRIPE_PROVIDER,
          external_customer_id: customer_id,
          external_subscription_id: external_subscription_id
        )
        attempt.update!(status: "completed")

        subscription
      end
    end

    private

    attr_reader :checkout_session

    def validate_checkout_session!
      raise_association_error("invalid_checkout_mode") unless checkout_session.mode == "subscription"
      raise_association_error("missing_checkout_session") if checkout_session_id.blank?
      raise_association_error("missing_customer") if customer_id.blank?
      raise_association_error("missing_subscription") if external_subscription_id.blank?
      raise_association_error("invalid_client_reference") unless checkout_session.client_reference_id == account_reference

      option = SubscriptionPlanCatalog.new.find(option_key)
      raise_association_error("invalid_option") unless option&.enabled?
    end

    def checkout_attempt
      StripeCheckoutAttemptReference.find!(attempt_reference)
    rescue StripeCheckoutAttemptReference::InvalidReferenceError
      code = attempt_reference.present? ? "invalid_checkout_attempt_reference" : "missing_checkout_attempt_reference"
      raise_association_error(code)
    end

    def validate_attempt!(attempt)
      unless WEBHOOK_ELIGIBLE_ATTEMPT_STATUSES.include?(attempt.status)
        raise_association_error("checkout_attempt_not_active")
      end
      raise_association_error("checkout_session_mismatch") unless attempt.stripe_checkout_session_id == checkout_session_id
      raise_association_error("customer_mismatch") unless attempt.stripe_customer_id == customer_id
      raise_association_error("option_mismatch") unless attempt.option_key == option_key
    end

    def validate_account_reference!(account_id)
      StripeWebhookAccountReferenceValidator.call(
        reference: account_reference,
        account_id: account_id
      )
    end

    def validate_identifiers!(subscription)
      if subscription.external_customer_id.present? && subscription.external_customer_id != customer_id
        raise_association_error("customer_mismatch")
      end
      if subscription.external_subscription_id.present? &&
          subscription.external_subscription_id != external_subscription_id
        raise_association_error("subscription_mismatch")
      end
      if identifier_used_by_another_account?(:external_customer_id, customer_id, subscription.account_id)
        raise_association_error("customer_account_mismatch")
      end
      if identifier_used_by_another_account?(:external_subscription_id, external_subscription_id, subscription.account_id)
        raise_association_error("subscription_account_mismatch")
      end
    end

    def identifier_used_by_another_account?(column, identifier, account_id)
      Subscription.where(provider: Subscription::STRIPE_PROVIDER, column => identifier)
        .where.not(account_id: account_id)
        .exists?
    end

    def metadata
      checkout_session.metadata || {}
    end

    def account_reference
      metadata[StripeCheckoutSessionCreator::ACCOUNT_REFERENCE_KEY].to_s
    end

    def attempt_reference
      metadata[StripeCheckoutSessionCreator::ATTEMPT_REFERENCE_KEY].to_s
    end

    def option_key
      metadata[StripeCheckoutSessionCreator::OPTION_KEY].to_s
    end

    def checkout_session_id
      checkout_session.id.to_s
    end

    def customer_id
      stripe_identifier(checkout_session.customer)
    end

    def external_subscription_id
      stripe_identifier(checkout_session.subscription)
    end

    def stripe_identifier(value)
      value.respond_to?(:id) ? value.id.to_s : value.to_s
    end

    def raise_association_error(code)
      raise StripeWebhookAssociationError, code
    end
  end
end
