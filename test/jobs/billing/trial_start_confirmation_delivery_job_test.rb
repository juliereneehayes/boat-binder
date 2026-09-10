require "test_helper"

module Billing
  class TrialStartConfirmationDeliveryJobTest < ActiveJob::TestCase
    setup do
      ActionMailer::Base.deliveries.clear
      @previous_monthly_price_id = Rails.configuration.x.stripe.self_managed_monthly_price_id
      @previous_annual_price_id = Rails.configuration.x.stripe.self_managed_annual_price_id
      Rails.configuration.x.stripe.self_managed_monthly_price_id = "price_job_monthly"
      Rails.configuration.x.stripe.self_managed_annual_price_id = "price_job_annual"
      @account = create_account(name: "Confirmation Delivery")
      @confirmation = create_confirmation
      clear_enqueued_jobs
    end

    teardown do
      Rails.configuration.x.stripe.self_managed_monthly_price_id = @previous_monthly_price_id
      Rails.configuration.x.stripe.self_managed_annual_price_id = @previous_annual_price_id
      ActionMailer::Base.deliveries.clear
      clear_enqueued_jobs
    end

    test "delivers once to the first verified eligible owner by membership order" do
      unverified = create_user(email: "unverified-delivery@example.test", role: "owner")
      recipient = verified_owner(email: "verified-delivery@example.test")
      later_recipient = verified_owner(email: "later-delivery@example.test")
      create_account_membership(user: unverified, account: @account)
      first_membership = create_account_membership(user: recipient, account: @account)
      later_membership = create_account_membership(user: later_recipient, account: @account)

      assert_operator first_membership.id, :<, later_membership.id
      assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
        TrialStartConfirmationDeliveryJob.perform_now(@confirmation.id)
      end
      assert_equal [ recipient.email_address ], ActionMailer::Base.deliveries.last.to
      assert_equal "delivered", @confirmation.reload.status

      assert_no_difference -> { ActionMailer::Base.deliveries.size } do
        TrialStartConfirmationDeliveryJob.perform_now(@confirmation.id)
      end
    end

    test "skips safely when only unverified inactive or cross-account owners exist" do
      unverified = create_user(email: "unverified-skip@example.test", role: "owner")
      inactive = verified_owner(email: "inactive-skip@example.test")
      inactive.update!(active: false)
      other_account = create_account(name: "Other Delivery Account")
      other_owner = verified_owner(email: "other-delivery@example.test")
      create_account_membership(user: unverified, account: @account)
      create_account_membership(user: inactive, account: @account)
      create_account_membership(user: other_owner, account: other_account)
      @account.contacts.create!(name: "Manual Contact", email: "manual-contact@example.test", role: "Owner")

      assert_no_difference -> { ActionMailer::Base.deliveries.size } do
        TrialStartConfirmationDeliveryJob.perform_now(@confirmation.id)
      end
      assert_equal "skipped", @confirmation.reload.status
      assert_equal "eligible_recipient_unavailable", @confirmation.error_code
    end

    test "delivery failure remains visible and a later retry does not duplicate delivery" do
      recipient = verified_owner(email: "retry-delivery@example.test")
      create_account_membership(user: recipient, account: @account)
      failing_message = Object.new
      failing_message.define_singleton_method(:deliver_now) { raise IOError, "private storage detail" }

      logs = capture_logs do
        with_mailer_confirmation(->(*) { failing_message }) do
          assert_raises(IOError) do
            TrialStartConfirmationDeliveryJob.perform_now(@confirmation.id)
          end
        end
      end

      assert_equal "failed", @confirmation.reload.status
      assert_equal "delivery_failed", @confirmation.error_code
      assert_includes logs, "exception_class=IOError"
      assert_not_includes logs, "private storage detail"
      assert_not_includes logs, @confirmation.external_subscription_id
      assert_not_includes logs, recipient.email_address

      assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
        TrialStartConfirmationDeliveryJob.perform_now(@confirmation.id)
      end
      assert_equal "delivered", @confirmation.reload.status
    end

    test "successful operational logging omits recipient and Stripe identifiers" do
      recipient = verified_owner(email: "private-recipient@example.test")
      create_account_membership(user: recipient, account: @account)

      logs = capture_logs do
        TrialStartConfirmationDeliveryJob.perform_now(@confirmation.id)
      end

      assert_includes logs, "result=delivered"
      assert_not_includes logs, recipient.email_address
      assert_not_includes logs, @confirmation.external_subscription_id
    end

    test "explicit recovery lets a new job deliver a stranded confirmation exactly once" do
      recipient = verified_owner(email: "recovered-delivery@example.test")
      create_account_membership(user: recipient, account: @account)
      @confirmation.update!(status: "delivering", active_job_id: "stranded-job")

      assert_no_difference -> { ActionMailer::Base.deliveries.size } do
        TrialStartConfirmationDeliveryJob.perform_now(@confirmation.id)
      end
      assert_equal "delivering", @confirmation.reload.status

      logs = capture_logs do
        @confirmation.reset_stranded_delivery_after_provider_check!
      end
      assert_includes logs, "result=operator_recovery_reset"
      assert_not_includes logs, recipient.email_address
      assert_not_includes logs, @confirmation.external_subscription_id

      assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
        TrialStartConfirmationDeliveryJob.perform_now(@confirmation.id)
      end
      assert_equal "delivered", @confirmation.reload.status

      assert_no_difference -> { ActionMailer::Base.deliveries.size } do
        TrialStartConfirmationDeliveryJob.perform_now(@confirmation.id)
      end
    end

    private

    def create_confirmation
      BillingTrialStartConfirmation.create!(
        account: @account,
        subscription: @account.subscription,
        external_subscription_id: "sub_confirmation_delivery",
        option_key: Billing::SubscriptionPlanCatalog::SELF_MANAGED_MONTHLY_KEY,
        trial_started_at: Time.zone.local(2026, 9, 9, 12),
        trial_ends_at: Time.zone.local(2026, 9, 16, 12)
      )
    end

    def verified_owner(email:)
      owner = create_user(email:, role: "owner")
      owner.update!(email_verification_sent_at: 1.hour.ago, email_verified_at: Time.current)
      owner
    end

    def capture_logs
      previous_logger = Rails.logger
      output = StringIO.new
      Rails.logger = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(output))
      yield
      output.string
    ensure
      Rails.logger = previous_logger
    end

    def with_mailer_confirmation(replacement)
      original_method = TrialStartConfirmationMailer.method(:confirmation)
      TrialStartConfirmationMailer.define_singleton_method(:confirmation) do |*arguments|
        replacement.call(*arguments)
      end
      yield
    ensure
      TrialStartConfirmationMailer.define_singleton_method(:confirmation, original_method)
    end
  end
end
