module Billing
  class SelfManagedEntitlement
    QUALIFYING_REASONS = %i[active trialing canceling_at_period_end].freeze
    private_constant :QUALIFYING_REASONS

    def initialize(account:, now: Time.current)
      @account = account
      @now = now
    end

    def qualifying?
      QUALIFYING_REASONS.include?(reason)
    end

    def reason
      evaluation.fetch(:reason)
    end

    def entitlement_ends_at
      evaluation[:entitlement_ends_at]
    end

    private

    attr_reader :account, :now

    def evaluation
      @evaluation ||= evaluate
    end

    def evaluate
      return result(:inactive_account) unless account.active?

      subscription = account.subscription
      return result(:missing_subscription) unless subscription
      return result(:wrong_provider) unless subscription.provider == Subscription::STRIPE_PROVIDER
      return result(:wrong_plan) unless subscription.plan == "self_managed"
      return result(:missing_verification) unless verified?(subscription)

      case subscription.status
      when "active"
        evaluate_active(subscription)
      when "trialing"
        evaluate_trial(subscription)
      else
        result(:non_qualifying_status)
      end
    end

    def verified?(subscription)
      subscription.persisted? &&
        subscription.external_customer_id.present? &&
        subscription.external_subscription_id.present? &&
        valid_time?(subscription.last_synced_at)
    end

    def evaluate_active(subscription)
      ends_at = subscription.current_period_ends_at
      return result(:missing_entitlement_end) unless valid_time?(ends_at)
      return result(:entitlement_expired, ends_at) unless ends_at > now

      reason = subscription.cancel_at_period_end? ? :canceling_at_period_end : :active
      result(reason, ends_at)
    end

    def evaluate_trial(subscription)
      ends_at = subscription.trial_ends_at
      return result(:missing_entitlement_end) unless valid_time?(ends_at)
      return result(:trial_expired, ends_at) unless ends_at > now

      result(:trialing, ends_at)
    end

    def valid_time?(value)
      value.is_a?(Time) || value.is_a?(ActiveSupport::TimeWithZone)
    end

    def result(reason, entitlement_ends_at = nil)
      { reason:, entitlement_ends_at: }
    end
  end
end
