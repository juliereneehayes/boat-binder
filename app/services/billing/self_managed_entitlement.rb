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

    def entitlement_ended_at
      lifecycle_evaluation[:entitlement_ended_at]
    end

    def entitlement_end_reason
      lifecycle_evaluation.fetch(:reason)
    end

    private

    attr_reader :account, :now

    def evaluation
      @evaluation ||= evaluate
    end

    def evaluate
      return result(:inactive_account) unless account.active?

      subscription_evaluation
    end

    def subscription_evaluation
      @subscription_evaluation ||= evaluate_subscription
    end

    def evaluate_subscription
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

    def subscription
      @subscription ||= account.subscription
    end

    def lifecycle_evaluation
      @lifecycle_evaluation ||= evaluate_lifecycle_end
    end

    def evaluate_lifecycle_end
      # Account activation gates application access, not verified Stripe lifecycle evidence.
      subscription_result = subscription_evaluation

      case subscription_result.fetch(:reason)
      when *QUALIFYING_REASONS
        lifecycle_result(:current_entitlement)
      when :trial_expired
        lifecycle_result(:verified_trial_end, subscription_result[:entitlement_ends_at])
      when :entitlement_expired
        lifecycle_result(:verified_paid_period_end, subscription_result[:entitlement_ends_at])
      when :non_qualifying_status
        evaluate_non_qualifying_lifecycle_end
      else
        lifecycle_result(subscription_result.fetch(:reason))
      end
    end

    def evaluate_non_qualifying_lifecycle_end
      return lifecycle_result(:past_due_policy_pending) if subscription.past_due?

      if subscription.canceled? && subscription.cancel_at_period_end?
        return verified_lifecycle_end(subscription.current_period_ends_at, :verified_paid_period_end)
      end

      if subscription.canceled? || subscription.expired? || subscription.suspended?
        return verified_lifecycle_end(subscription.entitlement_ended_at, :verified_lifecycle_end)
      end

      lifecycle_result(:entitlement_end_unavailable)
    end

    def verified_lifecycle_end(value, reason)
      return lifecycle_result(:entitlement_end_unavailable) unless valid_time?(value) && value <= now

      lifecycle_result(reason, value)
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

      qualifying_reason =
        subscription.cancel_at_period_end? ? :canceling_at_period_end : :active
      result(qualifying_reason, ends_at)
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

    def lifecycle_result(reason, entitlement_ended_at = nil)
      { reason:, entitlement_ended_at: }
    end
  end
end
