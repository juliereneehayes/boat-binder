module Billing
  class TrialStartConfirmationScheduler
    def self.call(subscription:, attempt:, option:)
      new(subscription:, attempt:, option:).call
    end

    def initialize(subscription:, attempt:, option:)
      @subscription = subscription
      @attempt = attempt
      @option = option
    end

    def call
      return unless eligible?

      key = {
        account_id: subscription.account_id,
        external_subscription_id: subscription.external_subscription_id,
        trial_started_at: subscription.trial_started_at
      }
      BillingTrialStartConfirmation.find_by(key) || create_confirmation!(key)
    rescue ActiveRecord::RecordNotUnique
      BillingTrialStartConfirmation.find_by!(key)
    rescue ActiveRecord::RecordInvalid => error
      raise unless error.record.errors.of_kind?(:trial_started_at, :taken)

      BillingTrialStartConfirmation.find_by!(key)
    end

    private

    attr_reader :attempt, :option, :subscription

    def eligible?
      !attempt.reactivation? && subscription.provider == Subscription::STRIPE_PROVIDER &&
        subscription.plan == SubscriptionPlanCatalog::SELF_MANAGED_PLAN_KEY &&
        subscription.trialing? && subscription.external_subscription_id.present? &&
        subscription.trial_started_at.present? && subscription.trial_ends_at.present? &&
        subscription.trial_ends_at > subscription.trial_started_at
    end

    def create_confirmation!(key)
      BillingTrialStartConfirmation.create!(
        **key,
        subscription:,
        option_key: option.key,
        trial_ends_at: subscription.trial_ends_at
      )
    end
  end
end
