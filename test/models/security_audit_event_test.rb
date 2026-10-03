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

  test "changed fields accept names but reject embedded values" do
    safe_event = SecurityAuditEvent.new(base_attributes.merge(changed_fields: %w[active role]))
    unsafe_event = SecurityAuditEvent.new(
      base_attributes.merge(changed_fields: [ "email_address=private@example.test" ])
    )

    assert safe_event.valid?
    assert_not unsafe_event.valid?
    assert_includes unsafe_event.errors[:changed_fields], "must contain field names without values"
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
