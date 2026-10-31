require "test_helper"

class RestrictedVesselAuthorizationTest < ActiveSupport::TestCase
  setup do
    @managed_account = create_account(name: "Managed Authorization Account")
    @managed_relationship = @managed_account.create_managed_service_relationship!(active: true)
    @managed_vessel = create_vessel(account: @managed_account, name: "Managed Authorization Vessel")

    @self_managed_account = create_account(name: "Self Managed Authorization Account")
    qualify_self_managed_subscription(@self_managed_account)
    @self_managed_vessel = create_vessel(
      account: @self_managed_account,
      name: "Self Managed Authorization Vessel"
    )
  end

  test "admin and captain can read and write restricted information only for managed service vessels" do
    admin = create_user(email: "restricted-admin@example.test", role: "admin")
    captain = create_user(email: "restricted-captain@example.test", role: "captain")

    [ admin, captain ].each do |user|
      assert restricted_readable?(user, @managed_vessel), user.role
      assert restricted_manageable?(user, @managed_vessel), user.role
      assert_not restricted_readable?(user, @self_managed_vessel), user.role
      assert_not restricted_manageable?(user, @self_managed_vessel), user.role
    end
  end

  test "managed service owners follow active membership read and write semantics" do
    reader = create_user(email: "managed-reader@example.test", role: "owner")
    editor = create_user(email: "managed-editor@example.test", role: "owner")
    inactive_member = create_user(email: "managed-inactive-member@example.test", role: "owner")
    create_account_membership(user: reader, account: @managed_account, access_level: "read_only")
    create_account_membership(user: editor, account: @managed_account, access_level: "editor")
    create_account_membership(
      user: inactive_member,
      account: @managed_account,
      access_level: "editor",
      active: false
    )

    assert restricted_readable?(reader, @managed_vessel)
    assert_not restricted_manageable?(reader, @managed_vessel)
    assert restricted_readable?(editor, @managed_vessel)
    assert restricted_manageable?(editor, @managed_vessel)
    assert_not restricted_readable?(inactive_member, @managed_vessel)
  end

  test "managed service owner access is independent of unrelated subscription plans and owner limits" do
    first_owner = create_user(email: "managed-first-owner@example.test", role: "owner")
    second_owner = create_user(email: "managed-second-owner@example.test", role: "owner")
    create_account_membership(user: first_owner, account: @managed_account, access_level: "editor")
    create_account_membership(user: second_owner, account: @managed_account, access_level: "editor")

    [ "legacy", "starter", "professional" ].each do |plan|
      @managed_account.subscription.update!(provider: "local", plan:, status: "active")

      assert restricted_manageable?(first_owner, @managed_vessel), plan
      assert restricted_manageable?(second_owner, @managed_vessel), plan
    end

    now = Time.current
    @managed_account.subscription.update_columns(
      provider: "stripe",
      plan: "self_managed",
      status: "active",
      external_customer_id: "cus_managed_multiple_owners",
      external_subscription_id: "sub_managed_multiple_owners",
      current_period_ends_at: now + 1.month,
      last_synced_at: now
    )
    assert_not Billing::OwnerUserLimit.compliant?(@managed_account.reload)
    assert restricted_manageable?(first_owner, @managed_vessel), "noncompliant Self Managed state"
    assert restricted_manageable?(second_owner, @managed_vessel), "noncompliant Self Managed state"
  end

  test "managed service owner access remains isolated across mixed account memberships" do
    other_account = create_account(name: "Other Managed Authorization Account")
    other_account.create_managed_service_relationship!(active: true)
    other_vessel = create_vessel(account: other_account, name: "Other Managed Authorization Vessel")
    owner = create_user(email: "mixed-managed-owner@example.test", role: "owner")
    create_account_membership(user: owner, account: @managed_account, access_level: "editor")
    create_account_membership(user: owner, account: other_account, access_level: "read_only")

    assert restricted_manageable?(owner, @managed_vessel)
    assert restricted_readable?(owner, other_vessel)
    assert_not restricted_manageable?(owner, other_vessel)

    third_account = create_account(name: "Unrelated Managed Authorization Account")
    third_account.create_managed_service_relationship!(active: true)
    third_vessel = create_vessel(account: third_account, name: "Unrelated Managed Authorization Vessel")
    assert_not restricted_readable?(owner, third_vessel)
  end

  test "inactive accounts users and missing users fail closed" do
    admin = create_user(email: "inactive-account-admin@example.test", role: "admin")
    inactive_owner = create_user(email: "inactive-managed-owner@example.test", role: "owner", active: false)
    create_account_membership(user: inactive_owner, account: @managed_account, access_level: "editor")

    @managed_account.update!(active: false)

    assert_not restricted_readable?(admin, @managed_vessel)
    assert_not restricted_manageable?(inactive_owner, @managed_vessel)
    assert_not restricted_readable?(nil, @managed_vessel)
  end

  test "qualified self managed owner can access only their own restricted vessel" do
    owner = create_user(email: "self-managed-restricted-owner@example.test", role: "owner")
    create_account_membership(user: owner, account: @self_managed_account, access_level: "editor")

    assert restricted_readable?(owner, @self_managed_vessel)
    assert restricted_manageable?(owner, @self_managed_vessel)
    assert_not restricted_readable?(owner, @managed_vessel)
    assert_not restricted_manageable?(owner, @managed_vessel)
    assert_raises(ActiveRecord::RecordNotFound) do
      restricted_scope(owner).find(@managed_vessel.id)
    end
  end

  test "invalid self managed entitlement states remain denied" do
    account = create_account(name: "Invalid Self Managed Authorization Account")
    vessel = create_vessel(account:, name: "Invalid Self Managed Authorization Vessel")
    owner = create_user(email: "invalid-self-managed-owner@example.test", role: "owner")
    create_account_membership(user: owner, account:, access_level: "editor")

    assert_not restricted_readable?(owner, vessel)
    assert_not restricted_manageable?(owner, vessel)

    qualify_self_managed_subscription(account)
    account.subscription.update!(last_synced_at: nil)

    assert_not restricted_readable?(owner, vessel)
    assert_not restricted_manageable?(owner, vessel)
  end

  test "noncompliant self managed owner count remains denied" do
    account = create_account(name: "Noncompliant Self Managed Authorization Account")
    vessel = create_vessel(account:, name: "Noncompliant Self Managed Authorization Vessel")
    first_owner = create_user(email: "noncompliant-first-owner@example.test", role: "owner")
    second_owner = create_user(email: "noncompliant-second-owner@example.test", role: "owner")
    create_account_membership(user: first_owner, account:, access_level: "editor")
    create_account_membership(user: second_owner, account:, access_level: "editor")
    now = Time.current
    account.subscription.update_columns(
      provider: "stripe",
      plan: "self_managed",
      status: "active",
      external_customer_id: "cus_noncompliant_restricted",
      external_subscription_id: "sub_noncompliant_restricted",
      current_period_ends_at: now + 1.month,
      last_synced_at: now
    )

    assert Billing::SelfManagedEntitlement.new(account: account.reload, now:).qualifying?
    assert_not Billing::OwnerUserLimit.compliant?(account)
    assert_not restricted_readable?(first_owner, vessel)
    assert_not restricted_manageable?(first_owner, vessel)
  end

  test "managed service revocation blocks the next authorization decision without deleting data" do
    admin = create_user(email: "revocation-admin@example.test", role: "admin")
    record = VesselAccessInformation::Persistence.save!(
      vessel: @managed_vessel,
      restricted_details: "Synthetic revocation test code 3381",
      actor: admin
    )

    assert restricted_readable?(admin, @managed_vessel)

    @managed_relationship.update!(active: false)

    assert_not restricted_readable?(admin, @managed_vessel)
    assert_not restricted_manageable?(admin, @managed_vessel)
    assert_equal record, VesselAccessInformation.find(record.id)
  end

  test "switching service model preserves account vessel and encrypted record identities" do
    admin = create_user(email: "service-switch-admin@example.test", role: "admin")
    record = VesselAccessInformation::Persistence.save!(
      vessel: @managed_vessel,
      restricted_details: "Synthetic service transition code 6802",
      actor: admin
    )
    original_ids = [ @managed_account.id, @managed_vessel.id, record.id ]

    @managed_relationship.update!(active: false)
    qualify_self_managed_subscription(@managed_account)

    assert_equal original_ids, [ @managed_account.reload.id, @managed_vessel.reload.id, record.reload.id ]
    assert_not restricted_readable?(admin, @managed_vessel)
  end

  test "relation scopes and predicates stay in parity across roles memberships and lifecycle states" do
    admin = create_user(email: "parity-admin@example.test", role: "admin")
    captain = create_user(email: "parity-captain@example.test", role: "captain")
    managed_reader = create_user(email: "parity-managed-reader@example.test", role: "owner")
    managed_editor = create_user(email: "parity-managed-editor@example.test", role: "owner")
    inactive_member = create_user(email: "parity-inactive-member@example.test", role: "owner")
    self_managed_owner = create_user(email: "parity-self-owner@example.test", role: "owner")
    create_account_membership(user: managed_reader, account: @managed_account, access_level: "read_only")
    create_account_membership(user: managed_editor, account: @managed_account, access_level: "editor")
    create_account_membership(
      user: inactive_member,
      account: @managed_account,
      access_level: "editor",
      active: false
    )
    self_managed_membership = create_account_membership(
      user: self_managed_owner,
      account: @self_managed_account,
      access_level: "read_only"
    )

    [ admin, captain ].each do |internal_user|
      assert_policy_parity(internal_user, @managed_vessel, readable: true, writable: true)
      assert_policy_parity(internal_user, @self_managed_vessel, readable: false, writable: false)
    end
    assert_policy_parity(managed_reader, @managed_vessel, readable: true, writable: false)
    assert_policy_parity(managed_editor, @managed_vessel, readable: true, writable: true)
    assert_policy_parity(inactive_member, @managed_vessel, readable: false, writable: false)
    assert_policy_parity(self_managed_owner, @self_managed_vessel, readable: true, writable: false)
    self_managed_membership.update!(access_level: "editor")
    assert_policy_parity(self_managed_owner, @self_managed_vessel, readable: true, writable: true)
    assert_policy_parity(self_managed_owner, @managed_vessel, readable: false, writable: false)

    @self_managed_account.subscription.update!(
      status: "canceled",
      entitlement_ended_at: 1.day.ago,
      current_period_ends_at: nil
    )
    assert_policy_parity(self_managed_owner, @self_managed_vessel, readable: true, writable: false)

    @managed_relationship.update!(active: false)
    assert_policy_parity(admin, @managed_vessel, readable: false, writable: false)
    assert_policy_parity(managed_editor, @managed_vessel, readable: false, writable: false)
  end

  private

  def assert_policy_parity(user, vessel, readable:, writable:)
    policy = Authorization::RestrictedVesselPolicy.new(user: user.reload)

    assert_equal readable, !!policy.readable?(vessel.reload)
    assert_equal readable, policy.readable_vessels.exists?(id: vessel.id)
    assert_equal writable, !!policy.writable?(vessel)
    assert_equal writable, policy.writable_vessels.exists?(id: vessel.id)
  end

  def restricted_readable?(user, vessel)
    restricted_scope(user).exists?(id: vessel.id)
  end

  def restricted_manageable?(user, vessel)
    authorization_controller(user).send(:manageable_restricted_vessels).exists?(id: vessel.id)
  end

  def restricted_scope(user)
    authorization_controller(user).send(:scoped_restricted_vessels)
  end

  def authorization_controller(user)
    ApplicationController.new.tap do |controller|
      controller.define_singleton_method(:current_user) { user }
    end
  end
end
