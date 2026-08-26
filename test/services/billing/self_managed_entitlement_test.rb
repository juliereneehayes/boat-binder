require "test_helper"

module Billing
  class SelfManagedEntitlementTest < ActiveSupport::TestCase
    BOUNDARY_DELTA = 0.000001

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
      end
    end

    test "trial qualifies strictly before verified trial end" do
      trial_end = @now + 7.days
      account = verified_account(status: "trialing", trial_ends_at: trial_end)
      entitlement = entitlement_for(account, now: trial_end - BOUNDARY_DELTA)

      assert entitlement.qualifying?
      assert_equal :trialing, entitlement.reason
      assert_equal trial_end, entitlement.entitlement_ends_at
      assert_nil entitlement.entitlement_ended_at
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
      end
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
    end

    test "immediate cancellation without a verified effective boundary remains unavailable" do
      account = verified_account(status: "canceled", canceled_at: @now - 1.hour)
      entitlement = entitlement_for(account)

      assert_nil entitlement.entitlement_ended_at
      assert_equal :entitlement_end_unavailable, entitlement.entitlement_end_reason
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
    end

    test "verified reactivation supersedes a historical ending boundary" do
      historical_end = @now - 1.month
      account = verified_account(
        status: "active",
        current_period_ends_at: @now + 1.month,
        entitlement_ended_at: historical_end
      )
      entitlement = entitlement_for(account)

      assert entitlement.qualifying?
      assert_nil entitlement.entitlement_ended_at
      assert_equal :current_entitlement, entitlement.entitlement_end_reason
      assert_equal historical_end, account.subscription.entitlement_ended_at
    end

    test "trial with no verified trial end fails closed" do
      account = verified_account(status: "trialing", trial_ends_at: nil)
      entitlement = entitlement_for(account)

      assert_not entitlement.qualifying?
      assert_equal :missing_entitlement_end, entitlement.reason
      assert_nil entitlement.entitlement_ends_at
      assert_nil entitlement.entitlement_ended_at
    end

    test "active subscription with no verified period end fails closed" do
      account = verified_account(status: "active", current_period_ends_at: nil)
      entitlement = entitlement_for(account)

      assert_not entitlement.qualifying?
      assert_equal :missing_entitlement_end, entitlement.reason
      assert_nil entitlement.entitlement_ends_at
      assert_nil entitlement.entitlement_ended_at
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
    end

    test "invalid entitlement end value fails closed" do
      account = verified_account(status: "active", current_period_ends_at: @now + 1.month)
      account.subscription.define_singleton_method(:current_period_ends_at) { "not-a-time" }
      entitlement = entitlement_for(account)

      assert_not entitlement.qualifying?
      assert_equal :missing_entitlement_end, entitlement.reason
      assert_nil entitlement.entitlement_ends_at
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
    end

    test "inactive account fails closed" do
      account = verified_account(status: "active", current_period_ends_at: @now + 1.month)
      account.update!(active: false)
      entitlement = entitlement_for(account)

      assert_not entitlement.qualifying?
      assert_equal :inactive_account, entitlement.reason
    end

    test "local legacy subscription fails closed" do
      account = create_account(name: unique_name("Local Legacy"))
      entitlement = entitlement_for(account)

      assert_not entitlement.qualifying?
      assert_equal :wrong_provider, entitlement.reason
      assert_nil entitlement.entitlement_ended_at
    end

    test "non Stripe provider fails closed" do
      account = verified_account(status: "active", current_period_ends_at: @now + 1.month)
      account.subscription.update!(provider: Subscription::LOCAL_PROVIDER)
      entitlement = entitlement_for(account)

      assert_not entitlement.qualifying?
      assert_equal :wrong_provider, entitlement.reason
    end

    test "non Self Managed plan fails closed" do
      account = verified_account(status: "active", current_period_ends_at: @now + 1.month)
      account.subscription.update!(plan: "professional")
      entitlement = entitlement_for(account)

      assert_not entitlement.qualifying?
      assert_equal :wrong_plan, entitlement.reason
    end

    test "missing Stripe identifiers or synchronization timestamp fail closed" do
      %i[external_customer_id external_subscription_id last_synced_at].each do |attribute|
        account = verified_account(status: "active", current_period_ends_at: @now + 1.month)
        account.subscription.update!(attribute => nil)
        entitlement = entitlement_for(account)

        assert_not entitlement.qualifying?, "#{attribute} should be required"
        assert_equal :missing_verification, entitlement.reason
        assert_nil entitlement.entitlement_ended_at
      end
    end

    test "unpersisted subscription state fails closed" do
      account = verified_account(status: "active", current_period_ends_at: @now + 1.month)
      account.association(:subscription).target = account.subscription.dup
      entitlement = entitlement_for(account)

      assert_not entitlement.qualifying?
      assert_equal :missing_verification, entitlement.reason
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
    ensure
      Stripe::Subscription.define_singleton_method(:retrieve, original_retrieve) if original_retrieve
    end

    private

    def entitlement_for(account, now: @now)
      SelfManagedEntitlement.new(account:, now:)
    end

    def verified_account(status:, trial_ends_at: @now + 7.days,
      current_period_ends_at: @now + 1.month, cancel_at_period_end: false,
      canceled_at: nil, entitlement_ended_at: nil, past_due_observed_at: nil)
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
