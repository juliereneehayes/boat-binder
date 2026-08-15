module Billing
  class StripeSubscriptionSynchronizer
    WEBHOOK_ELIGIBLE_ATTEMPT_STATUSES = %w[open replacing submitted completed].freeze
    STATUS_MAP = {
      "trialing" => "trialing",
      "active" => "active",
      "past_due" => "past_due",
      "canceled" => "canceled",
      "incomplete" => "suspended",
      "unpaid" => "suspended",
      "paused" => "suspended",
      "incomplete_expired" => "expired"
    }.freeze

    def self.call(event, before_retrieve: nil, &commit_wrapper)
      new(event).call(before_retrieve:, &commit_wrapper)
    end

    INVOICE_EVENT_TYPES = %w[invoice.paid invoice.payment_failed].freeze

    def initialize(event)
      @event = event
      @event_object = event.data.object
    end

    def call(before_retrieve: nil)
      event_option = resolve_event_option
      attempt = event_checkout_attempt

      StripeAccountReconciliationLock.call(account_id: attempt.account_id) do
        early_result = before_retrieve&.call
        next early_result if early_result

        validate_preflight!(attempt.account, attempt.id, event_option)
        canonical_subscription = retrieve_canonical_subscription
        canonical_option = resolve_option(canonical_subscription)
        commit = -> { commit!(attempt, event_option, canonical_subscription, canonical_option) }

        block_given? ? yield(commit) : commit.call
      end
    end

    private

    attr_reader :event, :event_object

    def commit!(attempt, event_option, canonical_subscription, canonical_option)
      StripeAccountStateLock.call(account: Account.find(attempt.account_id), attempt_id: attempt.id) do |subscription, locked_attempt|
        validate_locked_records!(subscription, locked_attempt)
        validate_event_source!(event_option, subscription, locked_attempt)
        validate_remote_subscription!(
          canonical_subscription,
          canonical_option,
          subscription,
          locked_attempt,
          expected_subscription_id: event_subscription_id
        )

        subscription.update!(synchronized_attributes(canonical_subscription, canonical_option))
        locked_attempt.update!(status: "completed") unless locked_attempt.status == "completed"
        subscription
      end
    end

    def validate_preflight!(account, attempt_id, option)
      StripeAccountStateLock.call(account: account, attempt_id: attempt_id) do |subscription, locked_attempt|
        validate_locked_records!(subscription, locked_attempt)
        validate_event_source!(option, subscription, locked_attempt)
      end
    end

    def retrieve_canonical_subscription
      Stripe::Subscription.retrieve(
        event_subscription_id,
        api_key: StripeConfiguration.secret_key!
      )
    end

    def resolve_option(remote_subscription)
      price_ids = subscription_items(remote_subscription)
        .filter_map { |item| stripe_identifier(item.price).presence }
        .uniq
      raise_association_error("invalid_price_count") unless price_ids.one?

      option = SubscriptionPlanCatalog.new.find_by_stripe_price_id(price_ids.first)
      raise_association_error("unknown_price") unless option
      remote_option_key = option_key(remote_subscription)
      raise_association_error("missing_option_key") if remote_option_key.blank?
      raise_association_error("option_price_mismatch") unless option.key == remote_option_key

      option
    end

    def resolve_event_option
      return resolve_invoice_option if invoice_event?

      resolve_option(event_object)
    end

    def resolve_invoice_option
      remote_option_key = metadata_option_key(invoice_metadata)
      raise_association_error("missing_option_key") if remote_option_key.blank?

      option = SubscriptionPlanCatalog.new.find(remote_option_key)
      raise_association_error("unknown_option") unless option

      option
    end

    def event_checkout_attempt
      return checkout_attempt_from_metadata(invoice_metadata) if invoice_event?

      checkout_attempt(event_object)
    end

    def checkout_attempt(remote_subscription)
      checkout_attempt_from_metadata(metadata(remote_subscription))
    end

    def checkout_attempt_from_metadata(source_metadata)
      reference = metadata_attempt_reference(source_metadata)
      StripeCheckoutAttemptReference.find!(reference)
    rescue StripeCheckoutAttemptReference::InvalidReferenceError
      code = reference.present? ? "invalid_checkout_attempt_reference" : "missing_checkout_attempt_reference"
      raise_association_error(code)
    end

    def validate_event_source!(option, subscription, attempt)
      if invoice_event?
        validate_invoice!(option, subscription, attempt)
      else
        validate_remote_subscription!(event_object, option, subscription, attempt)
      end
    end

    def validate_invoice!(option, subscription, attempt)
      remote_subscription_id = invoice_subscription_id
      remote_customer_id = invoice_customer_id
      raise_association_error("missing_invoice_subscription") if remote_subscription_id.blank?
      raise_association_error("missing_invoice_customer") if remote_customer_id.blank?
      raise_association_error("subscription_not_stripe_backed") unless subscription.provider == Subscription::STRIPE_PROVIDER

      StripeWebhookAccountReferenceValidator.call(
        reference: metadata_account_reference(invoice_metadata),
        account_id: subscription.account_id
      )
      referenced_attempt = checkout_attempt_from_metadata(invoice_metadata)
      raise_association_error("checkout_attempt_mismatch") unless referenced_attempt.id == attempt.id
      raise_association_error("customer_mismatch") unless attempt.stripe_customer_id == remote_customer_id
      raise_association_error("option_mismatch") unless attempt.option_key == option.key
      raise_association_error("customer_mismatch") unless subscription.external_customer_id == remote_customer_id
      raise_association_error("subscription_mismatch") unless subscription.external_subscription_id == remote_subscription_id
      if identifier_used_by_another_account?(:external_customer_id, remote_customer_id, subscription.account_id)
        raise_association_error("customer_account_mismatch")
      end
      if identifier_used_by_another_account?(:external_subscription_id, remote_subscription_id, subscription.account_id)
        raise_association_error("subscription_account_mismatch")
      end
    end

    def validate_locked_records!(subscription, attempt)
      raise_association_error("missing_local_subscription") unless subscription
      raise_association_error("missing_checkout_attempt") unless attempt
      unless WEBHOOK_ELIGIBLE_ATTEMPT_STATUSES.include?(attempt.status)
        raise_association_error("checkout_attempt_not_active")
      end
    end

    def validate_remote_subscription!(remote_subscription, option, subscription, attempt,
      expected_subscription_id: nil)
      remote_subscription_id = subscription_id(remote_subscription)
      remote_customer_id = customer_id(remote_subscription)
      raise_association_error("missing_subscription") if remote_subscription_id.blank?
      raise_association_error("missing_customer") if remote_customer_id.blank?
      if expected_subscription_id.present? && remote_subscription_id != expected_subscription_id
        raise_association_error("subscription_mismatch")
      end

      StripeWebhookAccountReferenceValidator.call(
        reference: account_reference(remote_subscription),
        account_id: subscription.account_id
      )
      referenced_attempt = checkout_attempt(remote_subscription)
      raise_association_error("checkout_attempt_mismatch") unless referenced_attempt.id == attempt.id
      raise_association_error("customer_mismatch") unless attempt.stripe_customer_id == remote_customer_id
      raise_association_error("option_mismatch") unless attempt.option_key == option.key
      if subscription.external_customer_id.present? && subscription.external_customer_id != remote_customer_id
        raise_association_error("customer_mismatch")
      end
      if subscription.external_subscription_id.present? &&
          subscription.external_subscription_id != remote_subscription_id
        raise_association_error("subscription_mismatch")
      end
      if identifier_used_by_another_account?(:external_customer_id, remote_customer_id, subscription.account_id)
        raise_association_error("customer_account_mismatch")
      end
      if identifier_used_by_another_account?(:external_subscription_id, remote_subscription_id, subscription.account_id)
        raise_association_error("subscription_account_mismatch")
      end
    end

    def synchronized_attributes(canonical_subscription, option)
      {
        provider: Subscription::STRIPE_PROVIDER,
        plan: option.plan_key,
        status: local_status(canonical_subscription),
        external_customer_id: customer_id(canonical_subscription),
        external_subscription_id: subscription_id(canonical_subscription),
        trial_ends_at: timestamp(canonical_subscription.trial_end),
        current_period_ends_at: current_period_end(canonical_subscription),
        cancel_at_period_end: canonical_subscription.cancel_at_period_end == true,
        canceled_at: timestamp(canonical_subscription.canceled_at),
        last_synced_at: Time.current
      }
    end

    def local_status(remote_subscription)
      STATUS_MAP.fetch(remote_subscription.status.to_s) do
        Rails.logger.warn(
          "Stripe subscription status fallback reason=unsupported_subscription_status " \
          "event_id=#{event.id} event_type=#{event.type}"
        )
        "suspended"
      end
    end

    def current_period_end(remote_subscription)
      timestamp(remote_subscription[:current_period_end]) ||
        subscription_items(remote_subscription).filter_map { |item| timestamp(item.current_period_end) }.max
    end

    def subscription_items(remote_subscription)
      remote_subscription.items&.data || []
    end

    def metadata(remote_subscription)
      remote_subscription.metadata || {}
    end

    def account_reference(remote_subscription)
      metadata(remote_subscription)[StripeCheckoutSessionCreator::ACCOUNT_REFERENCE_KEY].to_s
    end

    def attempt_reference(remote_subscription)
      metadata(remote_subscription)[StripeCheckoutSessionCreator::ATTEMPT_REFERENCE_KEY].to_s
    end

    def option_key(remote_subscription)
      metadata_option_key(metadata(remote_subscription))
    end

    def metadata_account_reference(source_metadata)
      source_metadata[StripeCheckoutSessionCreator::ACCOUNT_REFERENCE_KEY].to_s
    end

    def metadata_attempt_reference(source_metadata)
      source_metadata[StripeCheckoutSessionCreator::ATTEMPT_REFERENCE_KEY].to_s
    end

    def metadata_option_key(source_metadata)
      source_metadata[StripeCheckoutSessionCreator::OPTION_KEY].to_s
    end

    def invoice_event?
      INVOICE_EVENT_TYPES.include?(event.type.to_s)
    end

    def invoice_subscription_details
      parent = event_object.parent
      unless parent&.type.to_s == "subscription_details" && parent.subscription_details
        raise_association_error("invalid_invoice_parent")
      end

      parent.subscription_details
    end

    def invoice_metadata
      invoice_subscription_details.metadata || {}
    end

    def invoice_customer_id
      stripe_identifier(event_object.customer)
    end

    def invoice_subscription_id
      stripe_identifier(invoice_subscription_details.subscription)
    end

    def customer_id(remote_subscription)
      stripe_identifier(remote_subscription.customer)
    end

    def subscription_id(remote_subscription)
      remote_subscription.id.to_s
    end

    def event_subscription_id
      invoice_event? ? invoice_subscription_id : subscription_id(event_object)
    end

    def stripe_identifier(value)
      value.respond_to?(:id) ? value.id.to_s : value.to_s
    end

    def identifier_used_by_another_account?(column, identifier, account_id)
      Subscription.where(provider: Subscription::STRIPE_PROVIDER, column => identifier)
        .where.not(account_id: account_id)
        .exists?
    end

    def timestamp(value)
      return if value.blank?

      Time.at(Integer(value)).utc
    rescue ArgumentError, TypeError
      raise_association_error("invalid_timestamp")
    end

    def raise_association_error(code)
      raise StripeWebhookAssociationError, code
    end
  end
end
