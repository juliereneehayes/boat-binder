require "test_helper"

class Authorization::SelfManagedOwnerPolicyTest < ActiveSupport::TestCase
  setup do
    @now = Time.zone.local(2026, 10, 29, 12)
    @account = create_account(name: "Authoritative Self Managed Policy")
    @owner = create_user(email: "self-managed-policy-owner@example.test", role: "owner")
    @membership = create_account_membership(
      user: @owner,
      account: @account,
      access_level: "editor"
    )
  end

  test "current entitlement uses active membership access levels for reads and writes" do
    qualify_self_managed_subscription(@account, now: @now)

    assert_equal [ @account.id ], policy.readable_account_ids
    assert_equal [ @account.id ], policy.writable_account_ids

    @membership.update!(access_level: "read_only")

    assert_equal [ @account.id ], policy.readable_account_ids
    assert_empty policy.writable_account_ids
  end

  test "readable lifecycle phases remain independent from write entitlement" do
    @account.subscription.update!(
      provider: Subscription::STRIPE_PROVIDER,
      plan: "self_managed",
      status: "canceled",
      external_customer_id: "cus_policy_#{@account.id}",
      external_subscription_id: "sub_policy_#{@account.id}",
      entitlement_ended_at: @now - 1.day,
      last_synced_at: @now - 1.minute
    )

    assert_equal [ @account.id ], policy.readable_account_ids
    assert_empty policy.writable_account_ids

    @account.subscription.update!(status: "past_due", entitlement_ended_at: nil)

    assert_equal [ @account.id ], policy.readable_account_ids
    assert_empty policy.writable_account_ids
  end

  test "inactive membership user and retained lifecycle state fail closed" do
    qualify_self_managed_subscription(@account, now: @now)
    @membership.update!(active: false)

    assert_empty policy.readable_account_ids
    assert_empty policy.writable_account_ids

    @membership.update!(active: true)
    @owner.update!(active: false)

    assert_empty policy.readable_account_ids
    assert_empty policy.writable_account_ids

    @owner.update!(active: true)
    @account.subscription.update!(
      status: "canceled",
      entitlement_ended_at: @now - 4.months,
      current_period_ends_at: nil
    )

    assert_empty policy.readable_account_ids
    assert_empty policy.writable_account_ids
  end

  test "one request-scoped policy memoizes authoritative read and write decisions" do
    qualify_self_managed_subscription(@account, now: @now)
    request_policy = policy

    assert_equal [ @account.id ], request_policy.readable_account_ids
    assert_equal [ @account.id ], request_policy.writable_account_ids

    @membership.update!(access_level: "read_only")

    assert_equal [ @account.id ], request_policy.readable_account_ids
    assert_equal [ @account.id ], request_policy.writable_account_ids
    assert_empty policy.writable_account_ids
  end

  private

  def policy
    Authorization::SelfManagedOwnerPolicy.new(user: @owner.reload, now: @now)
  end
end
