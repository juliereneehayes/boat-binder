require "test_helper"

class SecurityAuditEventTest < ActiveSupport::TestCase
  setup do
    @actor = create_user(email: "audit-model-actor@example.test", role: "admin")
    @target = create_user(email: "audit-model-target@example.test", role: "captain")
  end

  test "security audit events are append only through Active Record" do
    event = create_event

    assert_raises(ActiveRecord::ReadOnlyRecord) { event.update!(outcome: "failed") }
    assert_raises(ActiveRecord::ReadOnlyRecord) { event.destroy! }
    assert_raises(ActiveRecord::ReadOnlyRecord) { event.delete }
    assert_raises(ActiveRecord::ReadOnlyRecord) do
      SecurityAuditEvent.where(id: event.id).update_all(outcome: "failed")
    end
    assert_raises(ActiveRecord::ReadOnlyRecord) do
      SecurityAuditEvent.where(id: event.id).delete_all
    end

    event.reload
    assert_equal "succeeded", event.outcome
  end

  test "target type and id must be present together" do
    event = SecurityAuditEvent.new(base_attributes.except(:target_id).merge(target_type: "User"))

    assert_not event.valid?
    assert_includes event.errors[:target], "type and id must be provided together"
  end

  test "changed fields accept only the approved semantic allowlist" do
    assert_equal %w[active password role], SecurityAuditEvent::CHANGED_FIELDS
    assert SecurityAuditEvent.new(
      base_attributes.merge(changed_fields: %w[active password role])
    ).valid?

    unsafe_fields = [
      "email_address",
      "password_is_some_secret",
      TEST_PASSWORD,
      BCrypt::Password.create(TEST_PASSWORD).to_s
    ]

    unsafe_fields.each do |unsafe_field|
      event = SecurityAuditEvent.new(base_attributes.merge(changed_fields: [ unsafe_field ]))
      assert_not event.valid?, unsafe_field
      assert_includes event.errors[:changed_fields], "must contain only approved semantic field names"
    end
  end

  test "historical identifiers survive deletion of referenced rows" do
    account = Account.create!(name: "Historical Audit Account", account_type: "client")
    event = SecurityAuditEvent.create!(base_attributes.merge(account:))
    actor_user_id = event.actor_user_id
    account_id = event.account_id
    target_id = event.target_id

    User.delete(@actor.id)
    User.delete(@target.id)
    Account.delete(account.id)
    event.reload

    assert_equal actor_user_id, event.actor_user_id
    assert_equal account_id, event.account_id
    assert_equal target_id, event.target_id
    assert_nil event.actor_user
    assert_nil event.account
  end

  private

  def create_event
    SecurityAuditEvent.create!(base_attributes)
  end

  def base_attributes
    {
      actor_user: @actor,
      action: "admin.user_security_changed",
      target_type: "User",
      target_id: @target.id,
      request_id: "test-request-id",
      outcome: "succeeded",
      changed_fields: %w[role]
    }
  end
end
