require "test_helper"

class ManagedServiceRelationship::TransitionTest < ActiveSupport::TestCase
  setup do
    @account = create_account(name: "Managed Service Transition Account")
    @vessel = create_vessel(account: @account, name: "Managed Service Transition Vessel")
    @admin = create_user(email: "managed-service-transition-admin@example.test", role: "admin")
  end

  test "active Admin activation and revocation are attributed and immediately effective" do
    relationship = nil
    assert_difference -> { SecurityAuditEvent.count }, 1 do
      relationship = ManagedServiceRelationship::Transition.call!(
        account: @account,
        active: true,
        actor: @admin,
        request_id: "managed-service-activate"
      )
    end

    activation = SecurityAuditEvent.order(:id).last
    assert relationship.active?
    assert ManagedServiceRelationship.effective_for?(@account)
    assert_equal "managed_service_relationship.activated", activation.action
    assert_equal @admin, activation.actor_user
    assert_equal @account, activation.account
    assert_equal relationship.id, activation.target_id
    assert_equal %w[active], activation.changed_fields
    assert_nil activation.source_ip

    record = VesselAccessInformation::Persistence.save!(
      vessel: @vessel,
      restricted_details: "Synthetic transition-preserved value",
      actor: @admin
    )

    assert_difference -> { SecurityAuditEvent.count }, 1 do
      ManagedServiceRelationship::Transition.call!(
        account: @account,
        active: false,
        actor: @admin,
        request_id: "managed-service-revoke"
      )
    end

    revocation = SecurityAuditEvent.order(:id).last
    assert_not relationship.reload.active?
    assert_not ManagedServiceRelationship.effective_for?(@account)
    assert_equal "managed_service_relationship.revoked", revocation.action
    assert_equal %w[active], revocation.changed_fields
    assert_nil revocation.source_ip
    assert_equal record, VesselAccessInformation.find(record.id)
    assert_empty Authorization::RestrictedVesselPolicy.new(user: @admin).readable_vessels
  end

  test "unchanged transition is a no-op without duplicate audit" do
    relationship = ManagedServiceRelationship::Transition.call!(
      account: @account,
      active: true,
      actor: @admin
    )

    assert_no_difference -> { SecurityAuditEvent.count } do
      result = ManagedServiceRelationship::Transition.call!(
        account: @account,
        active: true,
        actor: @admin
      )
      assert_equal relationship, result
    end
  end

  test "revoking an account that never had a relationship is a no-op" do
    assert_no_difference -> { ManagedServiceRelationship.count } do
      assert_no_difference -> { SecurityAuditEvent.count } do
        result = ManagedServiceRelationship::Transition.call!(
          account: @account,
          active: false,
          actor: @admin,
          request_id: "managed-service-absent-revoke"
        )

        assert_nil result
      end
    end
  end

  test "non Admin and inactive Admin transitions fail without state or audit" do
    captain = create_user(email: "managed-service-transition-captain@example.test", role: "captain")
    inactive_admin = create_user(
      email: "managed-service-transition-inactive-admin@example.test",
      role: "admin",
      active: false
    )

    [ captain, inactive_admin, nil ].each do |actor|
      assert_raises(ManagedServiceRelationship::Transition::AccessDenied) do
        ManagedServiceRelationship::Transition.call!(account: @account, active: true, actor:)
      end
    end

    assert_not @account.reload.managed_service_relationship
    assert_equal 0, SecurityAuditEvent.count
  end
end
