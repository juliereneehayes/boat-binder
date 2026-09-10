require "test_helper"

module Billing
  class TrialStartConfirmationSchedulerTest < ActiveSupport::TestCase
    include ActiveJob::TestHelper

    setup do
      @previous_queue_adapter = ActiveJob::Base.queue_adapter
      ActiveJob::Base.queue_adapter = :test
      clear_enqueued_jobs
      @account = create_account(name: "Trial Confirmation Scheduling")
      @subscription = @account.subscription
      @attempt = BillingCheckoutAttempt.create!(
        account: @account,
        option_key: SubscriptionPlanCatalog::SELF_MANAGED_MONTHLY_KEY,
        stripe_customer_id: "cus_trial_scheduler",
        stripe_checkout_session_id: "cs_trial_scheduler",
        idempotency_key: SecureRandom.uuid,
        status: "completed"
      )
      @option = catalog_option
      configure_trial
    end

    teardown do
      clear_enqueued_jobs
      ActiveJob::Base.queue_adapter = @previous_queue_adapter
    end

    test "eligible canonical trial creates only one confirmation across related calls" do
      assert_difference -> { BillingTrialStartConfirmation.count }, 1 do
        2.times do
          TrialStartConfirmationScheduler.call(
            subscription: @subscription,
            attempt: @attempt,
            option: @option
          )
        end
      end

      assert_equal 1, enqueued_jobs.count { |job| job[:job] == TrialStartConfirmationDeliveryJob }
    end

    test "does not schedule from non-trialing or incomplete canonical state" do
      ineligible_attributes = [
        { status: "active" },
        { trial_started_at: nil },
        { trial_ends_at: nil },
        { external_subscription_id: nil },
        { provider: Subscription::LOCAL_PROVIDER }
      ]

      ineligible_attributes.each do |attributes|
        configure_trial
        @subscription.update_columns(attributes)

        assert_no_difference -> { BillingTrialStartConfirmation.count } do
          TrialStartConfirmationScheduler.call(
            subscription: @subscription.reload,
            attempt: @attempt,
            option: @option
          )
        end
      end
    end

    test "does not schedule a confirmation for terminal reactivation attempts" do
      @attempt.update_column(:replaces_external_subscription_id, "sub_previous_entitlement")

      assert_no_difference -> { BillingTrialStartConfirmation.count } do
        TrialStartConfirmationScheduler.call(
          subscription: @subscription,
          attempt: @attempt,
          option: @option
        )
      end
    end

    private

    def configure_trial
      @subscription.update_columns(
        provider: Subscription::STRIPE_PROVIDER,
        plan: SubscriptionPlanCatalog::SELF_MANAGED_PLAN_KEY,
        status: "trialing",
        external_customer_id: "cus_trial_scheduler",
        external_subscription_id: "sub_trial_scheduler",
        trial_started_at: Time.zone.local(2026, 9, 9, 12),
        trial_ends_at: Time.zone.local(2026, 9, 16, 12)
      )
      @subscription.reload
    end

    def catalog_option
      SubscriptionPlanCatalog.new(
        price_ids: {
          SubscriptionPlanCatalog::SELF_MANAGED_MONTHLY_KEY => "price_trial_scheduler_monthly",
          SubscriptionPlanCatalog::SELF_MANAGED_ANNUAL_KEY => "price_trial_scheduler_annual"
        }
      ).fetch(SubscriptionPlanCatalog::SELF_MANAGED_MONTHLY_KEY)
    end
  end
end
