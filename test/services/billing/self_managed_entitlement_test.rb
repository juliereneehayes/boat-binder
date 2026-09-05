require "test_helper"

module Billing
  class SelfManagedEntitlementTest < ActiveSupport::TestCase
    BOUNDARY_DELTA = Rational(1, 1_000_000)

    setup do
      @now = Time.zone.local(2026, 8, 21, 12, 0, 0)
    end

    test "active verified Stripe Self Managed subscription qualifies" do
      account = verified_account(status: "active", current_period_ends_at: @now + 1.month)
      entitlement = entitlement_for(account)

      assert entitlement.qualifying?
      assert_equal :active, entitlement.reason
      assert_equal @now + 1.month, entitlement.entitlement_ends_at
      assert_nil entitlement.entitlement_ended_at
      assert_equal :current_entitlement, entitlement.entitlement_end_reason
      assert_equal :current_entitlement, entitlement.lifecycle_phase
    end

    test "active subscription fails at and after its verified current period end" do
      period_end = @now + 1.month
      account = verified_account(status: "active", current_period_ends_at: period_end)

      [ period_end, period_end + BOUNDARY_DELTA ].each do |evaluation_time|
        entitlement = entitlement_for(account, now: evaluation_time)

        assert_not entitlement.qualifying?
        assert_equal :entitlement_expired, entitlement.reason
        assert_equal period_end, entitlement.entitlement_ends_at
        assert_equal period_end, entitlement.entitlement_ended_at
        assert_equal :verified_paid_period_end, entitlement.entitlement_end_reason
        assert_equal :read_only_grace, entitlement.lifecycle_phase
      end
    end

    test "scheduled cancellation qualifies strictly before current period end" do
      period_end = @now + 1.month
      account = verified_account(
        status: "active",
        current_period_ends_at: period_end,
        cancel_at_period_end: true
      )

      entitlement = entitlement_for(account, now: period_end - BOUNDARY_DELTA)

      assert entitlement.qualifying?
      assert_equal :canceling_at_period_end, entitlement.reason
      assert_equal period_end, entitlement.entitlement_ends_at
      assert_nil entitlement.entitlement_ended_at
      assert_equal :current_entitlement, entitlement.lifecycle_phase
    end

    test "scheduled cancellation fails at and after current period end" do
      period_end = @now + 1.month
      account = verified_account(
        status: "active",
        current_period_ends_at: period_end,
        cancel_at_period_end: true
      )

      [ period_end, period_end + BOUNDARY_DELTA ].each do |evaluation_time|
        entitlement = entitlement_for(account, now: evaluation_time)

        assert_not entitlement.qualifying?
        assert_equal :entitlement_expired, entitlement.reason
        assert_equal period_end, entitlement.entitlement_ends_at
        assert_equal period_end, entitlement.entitlement_ended_at
        assert_equal :verified_paid_period_end, entitlement.entitlement_end_reason
        assert_equal :read_only_grace, entitlement.lifecycle_phase
      end
    end

    test "canonical cancel at schedules cancellation and caps entitlement at the exact boundary" do
      period_end = @now + 1.month
      cancel_at = @now + 2.weeks
      account = verified_account(
        status: "active",
        current_period_ends_at: period_end,
        cancel_at_period_end: false,
        cancel_at:
      )

      before_cancellation = entitlement_for(account, now: cancel_at - BOUNDARY_DELTA)
      assert before_cancellation.qualifying?
      assert_equal :canceling_at_period_end, before_cancellation.reason
      assert_equal cancel_at, before_cancellation.entitlement_ends_at

      at_cancellation = entitlement_for(account, now: cancel_at)
      assert_not at_cancellation.qualifying?
      assert_equal :entitlement_expired, at_cancellation.reason
      assert_equal cancel_at, at_cancellation.entitlement_ended_at
      assert_equal :read_only_grace, at_cancellation.lifecycle_phase
    end

    test "clearing canonical cancel at resumes normal active-period evaluation" do
      period_end = @now + 1.month
      account = verified_account(
        status: "active",
        current_period_ends_at: period_end,
        cancel_at: @now + 2.weeks
      )

      account.subscription.update!(cancel_at: nil)
      entitlement = entitlement_for(account)

      assert entitlement.qualifying?
      assert_equal :active, entitlement.reason
      assert_equal period_end, entitlement.entitlement_ends_at
    end

    test "trial qualifies strictly before verified trial end" do
      trial_end = @now + 7.days
      account = verified_account(status: "trialing", trial_ends_at: trial_end)
      entitlement = entitlement_for(account, now: trial_end - BOUNDARY_DELTA)

      assert entitlement.qualifying?
      assert_equal :trialing, entitlement.reason
      assert_equal trial_end, entitlement.entitlement_ends_at
      assert_nil entitlement.entitlement_ended_at
      assert_equal :current_entitlement, entitlement.lifecycle_phase
    end

    test "trial fails at and after verified trial end" do
      trial_end = @now + 7.days
      account = verified_account(status: "trialing", trial_ends_at: trial_end)

      [ trial_end, trial_end + BOUNDARY_DELTA ].each do |evaluation_time|
        entitlement = entitlement_for(account, now: evaluation_time)

        assert_not entitlement.qualifying?
        assert_equal :trial_expired, entitlement.reason
        assert_equal trial_end, entitlement.entitlement_ends_at
        assert_equal trial_end, entitlement.entitlement_ended_at
        assert_equal :verified_trial_end, entitlement.entitlement_end_reason
        assert_equal :read_only_grace, entitlement.lifecycle_phase
      end
    end

    test "canonical scheduled cancellation caps trial entitlement at its exact boundary" do
      trial_end = @now + 7.days
      cancel_at = @now + 3.days
      account = verified_account(
        status: "trialing",
        trial_ends_at: trial_end,
        cancel_at:
      )

      before_cancellation = entitlement_for(account, now: cancel_at - BOUNDARY_DELTA)
      assert before_cancellation.qualifying?
      assert_equal :trialing, before_cancellation.reason
      assert_equal cancel_at, before_cancellation.entitlement_ends_at

      after_cancellation = entitlement_for(account, now: cancel_at + BOUNDARY_DELTA)
      assert_not after_cancellation.qualifying?
      assert_equal :entitlement_expired, after_cancellation.reason
      assert_equal cancel_at, after_cancellation.entitlement_ends_at
    end

    test "scheduled cancellation after trial end does not extend trial entitlement" do
      trial_end = @now + 7.days
      account = verified_account(
        status: "trialing",
        trial_ends_at: trial_end,
        cancel_at: trial_end + 3.days
      )

      before_trial_end = entitlement_for(account, now: trial_end - BOUNDARY_DELTA)
      assert before_trial_end.qualifying?
      assert_equal :trialing, before_trial_end.reason
      assert_equal trial_end, before_trial_end.entitlement_ends_at

      after_trial_end = entitlement_for(account, now: trial_end + BOUNDARY_DELTA)
      assert_not after_trial_end.qualifying?
      assert_equal :trial_expired, after_trial_end.reason
      assert_equal trial_end, after_trial_end.entitlement_ends_at
    end

    test "legacy period-end cancellation caps trial at current period end" do
      trial_end = @now + 7.days
      period_end = @now + 3.days
      account = verified_account(
        status: "trialing",
        trial_ends_at: trial_end,
        current_period_ends_at: period_end,
        cancel_at_period_end: true
      )

      before_period_end = entitlement_for(account, now: period_end - BOUNDARY_DELTA)
      assert before_period_end.qualifying?
      assert_equal :trialing, before_period_end.reason
      assert_equal period_end, before_period_end.entitlement_ends_at

      after_period_end = entitlement_for(account, now: period_end + BOUNDARY_DELTA)
      assert_not after_period_end.qualifying?
      assert_equal :entitlement_expired, after_period_end.reason
      assert_equal period_end, after_period_end.entitlement_ends_at
    end

    test "scheduled cancellation ignores cancellation request time and ends at paid through boundary" do
      period_end = @now - 1.hour
      cancellation_requested_at = @now - 1.week
      account = verified_account(
        status: "canceled",
        current_period_ends_at: period_end,
        cancel_at_period_end: true,
        canceled_at: cancellation_requested_at,
        entitlement_ended_at: period_end
      )
      entitlement = entitlement_for(account)

      assert_equal period_end, entitlement.entitlement_ended_at
      assert_not_equal cancellation_requested_at, entitlement.entitlement_ended_at
      assert_equal :verified_paid_period_end, entitlement.entitlement_end_reason
      assert_equal :read_only_grace, entitlement.lifecycle_phase
    end

    test "cancellation reversal restores current evaluation without erasing history" do
      historical_end = @now - 1.month
      account = verified_account(
        status: "active",
        current_period_ends_at: @now + 1.month,
        cancel_at_period_end: true,
        entitlement_ended_at: historical_end
      )
      account.subscription.update!(cancel_at_period_end: false)
      entitlement = entitlement_for(account)

      assert entitlement.qualifying?
      assert_equal :active, entitlement.reason
      assert_nil entitlement.entitlement_ended_at
      assert_equal :current_entitlement, entitlement.lifecycle_phase
      assert_equal historical_end, account.subscription.entitlement_ended_at
    end

    test "immediate cancellation uses only a verified effective ending boundary" do
      effective_end = @now - 1.hour
      account = verified_account(
        status: "canceled",
        canceled_at: @now - 2.hours,
        entitlement_ended_at: effective_end
      )
      entitlement = entitlement_for(account)

      assert_equal effective_end, entitlement.entitlement_ended_at
      assert_equal :verified_lifecycle_end, entitlement.entitlement_end_reason
      assert_equal :read_only_grace, entitlement.lifecycle_phase
    end

    test "immediate cancellation without a verified effective boundary remains unavailable" do
      account = verified_account(status: "canceled", canceled_at: @now - 1.hour)
      entitlement = entitlement_for(account)

      assert_nil entitlement.entitlement_ended_at
      assert_equal :entitlement_end_unavailable, entitlement.entitlement_end_reason
      assert_equal :unavailable, entitlement.lifecycle_phase
    end

    test "verified ending boundary transitions exactly through grace retention and archive eligibility" do
      ended_at = Time.zone.local(2027, 3, 1, 12)
      account = verified_account(status: "canceled", entitlement_ended_at: ended_at)
      account.subscription.update!(last_synced_at: ended_at)
      grace_boundary = ended_at + 90.days
      archive_boundary = ended_at + 12.months

      expected_phases = {
        grace_boundary - BOUNDARY_DELTA => :read_only_grace,
        grace_boundary => :retained_inactive,
        grace_boundary + BOUNDARY_DELTA => :retained_inactive,
        archive_boundary - BOUNDARY_DELTA => :retained_inactive,
        archive_boundary => :archive_eligible,
        archive_boundary + BOUNDARY_DELTA => :archive_eligible
      }

      expected_phases.each do |evaluation_time, expected_phase|
        entitlement = entitlement_for(account, now: evaluation_time)

        assert_equal expected_phase, entitlement.lifecycle_phase
        assert_equal expected_phase, entitlement.lifecycle_phase
      end
    end

    test "suspended subscription requires manual review regardless of historical ending boundary" do
      historical_end = @now - 1.year
      account = verified_account(status: "suspended", entitlement_ended_at: historical_end)
      entitlement = entitlement_for(account)

      assert_not entitlement.qualifying?
      assert_equal :non_qualifying_status, entitlement.reason
      assert_equal historical_end, entitlement.entitlement_ended_at
      assert_equal :suspended_policy_pending, entitlement.entitlement_end_reason
      assert_equal :manual_review, entitlement.lifecycle_phase
      assert_equal historical_end, account.subscription.entitlement_ended_at
    end

    test "period end cancellation without paid through boundary remains unavailable" do
      account = verified_account(
        status: "canceled",
        current_period_ends_at: nil,
        cancel_at_period_end: true,
        entitlement_ended_at: @now - 1.month
      )
      entitlement = entitlement_for(account)

      assert_nil entitlement.entitlement_ended_at
      assert_equal :entitlement_end_unavailable, entitlement.entitlement_end_reason
      assert_equal :unavailable, entitlement.lifecycle_phase
    end

    test "past due timing remains distinct from the post entitlement boundary" do
      account = verified_account(
        status: "past_due",
        past_due_observed_at: @now - 1.hour,
        entitlement_ended_at: @now - 1.week
      )
      entitlement = entitlement_for(account)

      assert_nil entitlement.entitlement_ended_at
      assert_equal :past_due_policy_pending, entitlement.entitlement_end_reason
      assert_equal :payment_recovery_pending, entitlement.lifecycle_phase
    end

    test "verified reactivation supersedes a historical ending boundary" do
      historical_end = @now - 1.month
      historical_trial_end = @now - 2.months
      account = verified_account(
        status: "active",
        trial_ends_at: historical_trial_end,
        current_period_ends_at: @now + 1.month,
        entitlement_ended_at: historical_end
      )
      account_id = account.id
      subscription_id = account.subscription.id
      entitlement = entitlement_for(account)

      assert entitlement.qualifying?
      assert_nil entitlement.entitlement_ended_at
      assert_equal :current_entitlement, entitlement.entitlement_end_reason
      assert_equal :current_entitlement, entitlement.lifecycle_phase
      subscription = account.reload.subscription
      assert_equal account_id, account.id
      assert_equal subscription_id, subscription.id
      assert_equal historical_trial_end, subscription.trial_ends_at
      assert_equal historical_end, subscription.entitlement_ended_at
      assert_equal 1, Subscription.where(account:).count
    end

    test "trial with no verified trial end fails closed" do
      account = verified_account(status: "trialing", trial_ends_at: nil)
      entitlement = entitlement_for(account)

      assert_not entitlement.qualifying?
      assert_equal :missing_entitlement_end, entitlement.reason
      assert_nil entitlement.entitlement_ends_at
      assert_nil entitlement.entitlement_ended_at
      assert_equal :unavailable, entitlement.lifecycle_phase
    end

    test "active subscription with no verified period end fails closed" do
      account = verified_account(status: "active", current_period_ends_at: nil)
      entitlement = entitlement_for(account)

      assert_not entitlement.qualifying?
      assert_equal :missing_entitlement_end, entitlement.reason
      assert_nil entitlement.entitlement_ends_at
      assert_nil entitlement.entitlement_ended_at
      assert_equal :unavailable, entitlement.lifecycle_phase
    end

    test "scheduled cancellation with no verified period end fails closed" do
      account = verified_account(
        status: "active",
        current_period_ends_at: nil,
        cancel_at_period_end: true
      )
      entitlement = entitlement_for(account)

      assert_not entitlement.qualifying?
      assert_equal :missing_entitlement_end, entitlement.reason
      assert_equal :unavailable, entitlement.lifecycle_phase
    end

    test "invalid entitlement end value fails closed" do
      account = verified_account(status: "active", current_period_ends_at: @now + 1.month)
      account.subscription.define_singleton_method(:current_period_ends_at) { "not-a-time" }
      entitlement = entitlement_for(account)

      assert_not entitlement.qualifying?
      assert_equal :missing_entitlement_end, entitlement.reason
      assert_nil entitlement.entitlement_ends_at
      assert_equal :unavailable, entitlement.lifecycle_phase
    end

    test "missing subscription fails closed" do
      account = Account.create!(
        name: "No Subscription Account",
        account_type: "client",
        active: true,
        time_zone: Account::DEFAULT_TIME_ZONE
      )
      entitlement = entitlement_for(account)

      assert_not entitlement.qualifying?
      assert_equal :missing_subscription, entitlement.reason
      assert_equal :unavailable, entitlement.lifecycle_phase
    end

    test "inactive account blocks access without fabricating an end for a current Stripe entitlement" do
      account = verified_account(status: "active", current_period_ends_at: @now + 1.month)
      account.update!(active: false)
      entitlement = entitlement_for(account)

      assert_not entitlement.qualifying?
      assert_equal :inactive_account, entitlement.reason
      assert_nil entitlement.entitlement_ended_at
      assert_equal :current_entitlement, entitlement.entitlement_end_reason
      assert_equal :current_entitlement, entitlement.lifecycle_phase
    end

    test "inactive account retains a verified historical Stripe ending boundary" do
      historical_end = @now - 1.hour
      account = verified_account(status: "canceled", entitlement_ended_at: historical_end)
      account.update!(active: false)
      entitlement = entitlement_for(account)

      assert_not entitlement.qualifying?
      assert_equal :inactive_account, entitlement.reason
      assert_equal historical_end, entitlement.entitlement_ended_at
      assert_equal :verified_lifecycle_end, entitlement.entitlement_end_reason
      assert_equal :read_only_grace, entitlement.lifecycle_phase
    end

    test "local legacy subscription fails closed" do
      account = create_account(name: unique_name("Local Legacy"))
      entitlement = entitlement_for(account)

      assert_not entitlement.qualifying?
      assert_equal :wrong_provider, entitlement.reason
      assert_nil entitlement.entitlement_ended_at
      assert_equal :unavailable, entitlement.lifecycle_phase
    end

    test "local pending Checkout is a deliberate non-entitled onboarding phase" do
      account = create_account(name: unique_name("Pending Checkout"))
      account.subscription.update!(Subscription.pending_checkout_attributes)
      entitlement = entitlement_for(account)

      assert_not entitlement.qualifying?
      assert_equal :awaiting_checkout, entitlement.reason
      assert_nil entitlement.entitlement_ends_at
      assert_nil entitlement.entitlement_ended_at
      assert_equal :awaiting_checkout, entitlement.entitlement_end_reason
      assert_equal :awaiting_checkout, entitlement.lifecycle_phase
    end

    test "non Stripe provider fails closed" do
      account = verified_account(status: "active", current_period_ends_at: @now + 1.month)
      account.subscription.update!(provider: Subscription::LOCAL_PROVIDER)
      entitlement = entitlement_for(account)

      assert_not entitlement.qualifying?
      assert_equal :wrong_provider, entitlement.reason
      assert_equal :unavailable, entitlement.lifecycle_phase
    end

    test "non Self Managed plan fails closed" do
      account = verified_account(status: "active", current_period_ends_at: @now + 1.month)
      account.subscription.update!(plan: "professional")
      entitlement = entitlement_for(account)

      assert_not entitlement.qualifying?
      assert_equal :wrong_plan, entitlement.reason
      assert_equal :unavailable, entitlement.lifecycle_phase
    end

    test "missing Stripe identifiers or synchronization timestamp fail closed" do
      %i[external_customer_id external_subscription_id last_synced_at].each do |attribute|
        account = verified_account(status: "active", current_period_ends_at: @now + 1.month)
        account.subscription.update!(attribute => nil)
        entitlement = entitlement_for(account)

        assert_not entitlement.qualifying?, "#{attribute} should be required"
        assert_equal :missing_verification, entitlement.reason
        assert_nil entitlement.entitlement_ended_at
        assert_equal :unavailable, entitlement.lifecycle_phase
      end
    end

    test "unpersisted subscription state fails closed" do
      account = verified_account(status: "active", current_period_ends_at: @now + 1.month)
      account.association(:subscription).target = account.subscription.dup
      entitlement = entitlement_for(account)

      assert_not entitlement.qualifying?
      assert_equal :missing_verification, entitlement.reason
      assert_equal :unavailable, entitlement.lifecycle_phase
    end

    test "every locally supported non qualifying status fails closed" do
      non_qualifying_statuses = Subscription::STATUSES - %w[active trialing]

      non_qualifying_statuses.each do |status|
        account = verified_account(status:, current_period_ends_at: @now + 1.month)
        entitlement = entitlement_for(account)

        assert_not entitlement.qualifying?, "#{status} should not qualify"
        assert_equal :non_qualifying_status, entitlement.reason
        assert_nil entitlement.entitlement_ends_at
      end
    end

    test "unknown status fails closed" do
      account = verified_account(status: "active", current_period_ends_at: @now + 1.month)
      account.subscription.status = "future_status"
      entitlement = entitlement_for(account)

      assert_not entitlement.qualifying?
      assert_equal :non_qualifying_status, entitlement.reason
      assert_equal :unavailable, entitlement.lifecycle_phase
    end

    test "evaluation does not make a synchronous Stripe request" do
      account = verified_account(status: "active", current_period_ends_at: @now + 1.month)
      original_retrieve = Stripe::Subscription.method(:retrieve)
      Stripe::Subscription.define_singleton_method(:retrieve) do |*|
        raise "Entitlement evaluation called Stripe"
      end

      entitlement = entitlement_for(account)

      assert entitlement.qualifying?
      assert_nil entitlement.entitlement_ended_at
      assert_equal :current_entitlement, entitlement.lifecycle_phase
    ensure
      Stripe::Subscription.define_singleton_method(:retrieve, original_retrieve) if original_retrieve
    end

    private

    def entitlement_for(account, now: @now)
      SelfManagedEntitlement.new(account:, now:)
    end

    def verified_account(status:, trial_ends_at: @now + 7.days,
      current_period_ends_at: @now + 1.month, cancel_at_period_end: false,
      cancel_at: nil, canceled_at: nil, entitlement_ended_at: nil, past_due_observed_at: nil)
      account = create_account(name: unique_name("Verified Self Managed"))
      account.subscription.update!(
        provider: Subscription::STRIPE_PROVIDER,
        plan: "self_managed",
        status:,
        external_customer_id: "cus_#{account.id}",
        external_subscription_id: "sub_#{account.id}",
        trial_ends_at:,
        current_period_ends_at:,
        cancel_at_period_end:,
        cancel_at:,
        canceled_at:,
        entitlement_ended_at:,
        past_due_observed_at:,
        last_synced_at: @now - 1.hour
      )
      account
    end

    def unique_name(prefix)
      "#{prefix} #{SecureRandom.hex(6)}"
    end
  end
end
