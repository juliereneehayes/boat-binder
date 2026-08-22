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
    end

    test "active subscription fails at its verified current period end" do
      period_end = @now + 1.month
      account = verified_account(status: "active", current_period_ends_at: period_end)
      entitlement = entitlement_for(account, now: period_end)

      assert_not entitlement.qualifying?
      assert_equal :entitlement_expired, entitlement.reason
      assert_equal period_end, entitlement.entitlement_ends_at
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
      end
    end

    test "trial qualifies strictly before verified trial end" do
      trial_end = @now + 7.days
      account = verified_account(status: "trialing", trial_ends_at: trial_end)
      entitlement = entitlement_for(account, now: trial_end - BOUNDARY_DELTA)

      assert entitlement.qualifying?
      assert_equal :trialing, entitlement.reason
      assert_equal trial_end, entitlement.entitlement_ends_at
    end

    test "trial fails at and after verified trial end" do
      trial_end = @now + 7.days
      account = verified_account(status: "trialing", trial_ends_at: trial_end)

      [ trial_end, trial_end + BOUNDARY_DELTA ].each do |evaluation_time|
        entitlement = entitlement_for(account, now: evaluation_time)

        assert_not entitlement.qualifying?
        assert_equal :trial_expired, entitlement.reason
        assert_equal trial_end, entitlement.entitlement_ends_at
      end
    end

    test "trial with no verified trial end fails closed" do
      account = verified_account(status: "trialing", trial_ends_at: nil)
      entitlement = entitlement_for(account)

      assert_not entitlement.qualifying?
      assert_equal :missing_entitlement_end, entitlement.reason
      assert_nil entitlement.entitlement_ends_at
    end

    test "active subscription with no verified period end fails closed" do
      account = verified_account(status: "active", current_period_ends_at: nil)
      entitlement = entitlement_for(account)

      assert_not entitlement.qualifying?
      assert_equal :missing_entitlement_end, entitlement.reason
      assert_nil entitlement.entitlement_ends_at
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

      assert entitlement_for(account).qualifying?
    ensure
      Stripe::Subscription.define_singleton_method(:retrieve, original_retrieve) if original_retrieve
    end

    private

    def entitlement_for(account, now: @now)
      SelfManagedEntitlement.new(account:, now:)
    end

    def verified_account(status:, trial_ends_at: @now + 7.days,
      current_period_ends_at: @now + 1.month, cancel_at_period_end: false)
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
        last_synced_at: @now - 1.hour
      )
      account
    end

    def unique_name(prefix)
      "#{prefix} #{SecureRandom.hex(6)}"
    end
  end
end
