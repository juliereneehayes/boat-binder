module Billing
  class StripeSubscriptionSynchronizer
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

    def self.call(stripe_subscription)
      new(stripe_subscription).call
    end

    def initialize(stripe_subscription)
      @stripe_subscription = stripe_subscription
    end

    def call
      option = resolve_option
      subscription = resolve_subscription

      subscription.with_lock do
        subscription.reload
        validate_association!(subscription)
        subscription.update!(synchronized_attributes(option))
      end

      subscription
    end

    private

    attr_reader :stripe_subscription

    def resolve_option
      price_ids = subscription_items.filter_map { |item| stripe_identifier(item.price).presence }.uniq
      raise_association_error("invalid_price_count") unless price_ids.one?

      option = SubscriptionPlanCatalog.new.find_by_stripe_price_id(price_ids.first)
      raise_association_error("unknown_price") unless option&.enabled?
      if option_key.present? && option.key != option_key
        raise_association_error("option_price_mismatch")
      end

      option
    end

    def resolve_subscription
      subscriptions = subscriptions_for(:external_subscription_id, external_subscription_id)
      return subscriptions.first if subscriptions.one?
      raise_association_error("subscription_account_mismatch") if subscriptions.many?

      subscriptions = subscriptions_for(:external_customer_id, customer_id)
      return subscriptions.first if subscriptions.one?

      raise_association_error("customer_account_mismatch")
    end

    def validate_association!(subscription)
      raise_association_error("missing_subscription") if external_subscription_id.blank?
      raise_association_error("missing_customer") if customer_id.blank?
      StripeWebhookAccountReferenceValidator.call(
        reference: account_reference,
        account_id: subscription.account_id
      )
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

    def synchronized_attributes(option)
      {
        provider: Subscription::STRIPE_PROVIDER,
        plan: option.plan_key,
        status: local_status,
        external_customer_id: customer_id,
        external_subscription_id: external_subscription_id,
        trial_ends_at: timestamp(stripe_subscription.trial_end),
        current_period_ends_at: current_period_end,
        cancel_at_period_end: stripe_subscription.cancel_at_period_end == true,
        canceled_at: timestamp(stripe_subscription.canceled_at),
        last_synced_at: Time.current
      }
    end

    def local_status
      STATUS_MAP.fetch(stripe_subscription.status.to_s) do
        raise_association_error("unsupported_subscription_status")
      end
    end

    def current_period_end
      timestamp(stripe_subscription[:current_period_end]) ||
        subscription_items.filter_map { |item| timestamp(item.current_period_end) }.max
    end

    def subscription_items
      stripe_subscription.items&.data || []
    end

    def metadata
      stripe_subscription.metadata || {}
    end

    def account_reference
      metadata[StripeCheckoutSessionCreator::ACCOUNT_REFERENCE_KEY].to_s
    end

    def option_key
      metadata[StripeCheckoutSessionCreator::OPTION_KEY].to_s
    end

    def customer_id
      stripe_identifier(stripe_subscription.customer)
    end

    def external_subscription_id
      stripe_subscription.id.to_s
    end

    def stripe_identifier(value)
      value.respond_to?(:id) ? value.id.to_s : value.to_s
    end

    def identifier_used_by_another_account?(column, identifier, account_id)
      Subscription.where(provider: Subscription::STRIPE_PROVIDER, column => identifier)
        .where.not(account_id: account_id)
        .exists?
    end

    def subscriptions_for(column, identifier)
      return Subscription.none if identifier.blank?

      Subscription.where(provider: Subscription::STRIPE_PROVIDER, column => identifier).limit(2).to_a
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
