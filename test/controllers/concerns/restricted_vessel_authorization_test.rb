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

  private

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
