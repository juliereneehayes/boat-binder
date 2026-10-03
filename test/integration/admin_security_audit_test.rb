require "test_helper"

class AdminSecurityAuditTest < ActionDispatch::IntegrationTest
  setup do
    @admin = create_user(email: "security-audit-admin@example.test", role: "admin")
    @target = create_user(email: "security-audit-target@example.test", role: "captain", name: "Target User")
    sign_in_as(@admin)
  end

  test "successful security update writes one minimized event" do
    target_session = Session.create_for!(
      user: @target,
      user_agent: "Sensitive target browser",
      ip_address: "192.0.2.30"
    )

    assert_difference -> { SecurityAuditEvent.count }, 1 do
      patch admin_user_path(@target), params: { user: target_params(
        active: "0",
        password: NEW_TEST_PASSWORD,
        password_confirmation: NEW_TEST_PASSWORD,
        role: "admin"
      ) }
    end

    assert_redirected_to admin_users_path
    assert_not Session.exists?(target_session.id)

    event = SecurityAuditEvent.order(:id).last
    assert_equal "admin.user_security_changed", event.action
    assert_equal @admin.id, event.actor_user_id
    assert_nil event.account_id
    assert_equal "User", event.target_type
    assert_equal @target.id, event.target_id
    assert_equal "succeeded", event.outcome
    assert_equal %w[active password role], event.changed_fields
    assert event.request_id.present?
    assert_nil event.source_ip

    serialized_event = event.attributes.to_json
    assert_not_includes serialized_event, @target.email_address
    assert_not_includes serialized_event, NEW_TEST_PASSWORD
    assert_not_includes SecurityAuditEvent.column_names, "session_id"
  end

  test "admin user creation writes an event without password values" do
    assert_difference -> { SecurityAuditEvent.count }, 1 do
      post admin_users_path, params: { user: {
        name: "New Captain",
        email_address: "new-audited-captain@example.test",
        role: "captain",
        active: "1",
        send_invitation: "0",
        password: TEST_PASSWORD,
        password_confirmation: TEST_PASSWORD,
        account_ids: []
      } }
    end

    created_user = User.find_by!(email_address: "new-audited-captain@example.test")
    event = SecurityAuditEvent.order(:id).last

    assert_redirected_to admin_users_path
    assert_equal "admin.user_created", event.action
    assert_equal @admin.id, event.actor_user_id
    assert_equal created_user.id, event.target_id
    assert_equal %w[active password role], event.changed_fields
    assert_not_includes event.attributes.to_json, TEST_PASSWORD
  end

  test "owner security changes are attributed to every affected account" do
    first_account = create_account(name: "First Audited Owner Account")
    second_account = create_account(name: "Second Audited Owner Account")
    owner = create_user(email: "audited-owner@example.test", role: "owner", name: "Audited Owner")
    create_account_membership(user: owner, account: first_account)
    create_account_membership(user: owner, account: second_account)

    assert_difference -> { SecurityAuditEvent.count }, 2 do
      patch admin_user_path(owner), params: { user: {
        name: owner.name,
        email_address: owner.email_address,
        role: "captain",
        active: "1",
        password: "",
        password_confirmation: ""
      } }
    end

    events = SecurityAuditEvent.where(target_type: "User", target_id: owner.id).order(:account_id)
    assert_redirected_to admin_users_path
    assert_equal [ first_account.id, second_account.id ], events.pluck(:account_id)
    assert_equal [ "role" ], events.first.changed_fields
    assert_equal events.first, SecurityAuditEvent.for_account(first_account).sole
    assert_equal events.second, SecurityAuditEvent.for_account(second_account).sole
  end

  test "profile-only update does not create a security event" do
    assert_no_difference -> { SecurityAuditEvent.count } do
      patch admin_user_path(@target), params: { user: target_params(name: "Updated Target") }
    end

    assert_redirected_to admin_users_path
    assert_equal "Updated Target", @target.reload.name
  end

  test "failed update creates no event and preserves sessions" do
    target_session = Session.create_for!(
      user: @target,
      user_agent: "Preserved target browser",
      ip_address: "192.0.2.31"
    )

    assert_no_difference -> { SecurityAuditEvent.count } do
      patch admin_user_path(@target), params: { user: target_params(
        password: NEW_TEST_PASSWORD,
        password_confirmation: "does not match"
      ) }
    end

    assert_response :unprocessable_entity
    assert Session.exists?(target_session.id)
  end

  test "audit failure rolls back the security change and session revocation" do
    target_session = Session.create_for!(
      user: @target,
      user_agent: "Rollback target browser",
      ip_address: "192.0.2.32"
    )

    with_audit_recorder(->(**) { raise "audit unavailable" }) do
      assert_raises(RuntimeError) do
        patch admin_user_path(@target), params: { user: target_params(role: "admin") }
      end
    end

    assert @target.reload.captain?
    assert Session.exists?(target_session.id)
    assert_equal 0, SecurityAuditEvent.count
  end

  private

  def with_audit_recorder(replacement)
    original = SecurityAudit::Recorder.method(:record!)
    SecurityAudit::Recorder.define_singleton_method(:record!, replacement)
    yield
  ensure
    SecurityAudit::Recorder.define_singleton_method(:record!, original)
  end

  def target_params(overrides = {})
    {
      name: @target.name,
      email_address: @target.email_address,
      role: @target.role,
      active: @target.active? ? "1" : "0",
      password: "",
      password_confirmation: ""
    }.merge(overrides)
  end
end
