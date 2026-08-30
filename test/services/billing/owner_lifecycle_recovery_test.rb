require "test_helper"

module Billing
  class OwnerLifecycleRecoveryTest < ActiveSupport::TestCase
    setup do
      @now = Time.zone.local(2026, 8, 29, 12)
      @account = create_account(name: "Recovery Service Account")
      @owner = create_user(email: "recovery-service@example.test", role: "owner")
      @editor = create_account_membership(user: @owner, account: @account, access_level: "editor")
    end

    test "ordinary current entitlement stays invisible while either canonical schedule is actionable" do
      configure_subscription(status: "active", current_period_ends_at: @now + 1.month)
      recovery = build_recovery

      assert_not recovery.visible?
      assert_nil recovery.export_context

      @account.subscription.update!(cancel_at_period_end: true)
      recovery = build_recovery

      assert recovery.visible?
      assert recovery.scheduled_cancellation?
      assert_equal "scheduled_cancellation", recovery.export_context
      assert recovery.billing_portal_available?
      assert_not recovery.reactivation_available?

      cancel_at = @now + 2.weeks
      @account.subscription.update!(cancel_at_period_end: false, cancel_at:)
      recovery = build_recovery

      assert recovery.visible?
      assert recovery.scheduled_cancellation?
      assert_equal cancel_at, recovery.date
      assert recovery.billing_portal_available?
      assert recovery.export_available?
      assert_not recovery.reactivation_available?
    end

    test "payment recovery allows portal and export but not terminal reactivation" do
      configure_subscription(status: "past_due")
      recovery = build_recovery

      assert_equal :payment_recovery_pending, recovery.phase
      assert recovery.billing_portal_available?
      assert recovery.export_available?
      assert_not recovery.reactivation_available?
    end

    test "read only grace retained and archive phases expose eligible recovery actions" do
      {
        @now - 1.day => :read_only_grace,
        @now - 4.months => :retained_inactive,
        @now - 13.months => :archive_eligible
      }.each do |ended_at, expected_phase|
        configure_subscription(status: "canceled", entitlement_ended_at: ended_at)
        recovery = build_recovery

        assert_equal expected_phase, recovery.phase
        assert recovery.reactivation_available?
        assert recovery.export_available?
        assert_not recovery.billing_portal_available?
      end
    end

    test "read only membership can request approved exports but cannot use billing actions" do
      @editor.update!(access_level: "read_only")
      configure_subscription(status: "canceled", entitlement_ended_at: @now - 4.months)
      recovery = build_recovery

      assert recovery.export_available?
      assert_not recovery.billing_portal_available?
      assert_not recovery.reactivation_available?
    end

    test "manual and unavailable phases offer no automated action" do
      configure_subscription(status: "suspended", entitlement_ended_at: @now - 1.day)
      recovery = build_recovery

      assert_equal :manual_review, recovery.phase
      assert_not recovery.export_available?
      assert_not recovery.billing_portal_available?
      assert_not recovery.reactivation_available?

      @account.subscription.destroy!
      recovery = build_recovery
      assert_equal :unavailable, recovery.phase
      assert_not recovery.export_available?
    end

    private

    def build_recovery
      OwnerLifecycleRecovery.new(account: @account.reload, membership: @editor.reload, now: @now)
    end

    def configure_subscription(status:, current_period_ends_at: nil, entitlement_ended_at: nil)
      @account.subscription.update!(
        provider: Subscription::STRIPE_PROVIDER,
        plan: "self_managed",
        status:,
        external_customer_id: "cus_recovery_service",
        external_subscription_id: "sub_recovery_service",
        current_period_ends_at:,
        entitlement_ended_at:,
        cancel_at_period_end: false,
        cancel_at: nil,
        last_synced_at: @now - 1.minute
      )
    end
  end
end
