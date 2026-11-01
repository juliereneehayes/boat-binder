require "test_helper"

class VesselAccessInformation::RevealerTest < ActiveSupport::TestCase
  setup do
    @account = create_account(name: "Restricted Reveal Account")
    @relationship = @account.create_managed_service_relationship!(active: true)
    @vessel = create_vessel(account: @account, name: "Restricted Reveal Vessel")
    @admin = create_user(email: "restricted-revealer@example.test", role: "admin")
    @record = VesselAccessInformation::Persistence.update_fields!(
      vessel: @vessel,
      updates: {
        marina_gate_code: { operation: "replace", value: "Synthetic reveal gate 4512" },
        lockbox_code: { operation: "replace", value: "Synthetic unrevealed lockbox 8054" }
      },
      actor: @admin
    )
  end

  test "reveals only one authorized field and audits its semantic name" do
    value = VesselAccessInformation::Revealer.reveal!(
      vessel: @vessel,
      field: "marina_gate_code",
      actor: @admin,
      request_id: "restricted-reveal-success"
    )

    assert_equal "Synthetic reveal gate 4512", value
    event = SecurityAuditEvent.find_by!(request_id: "restricted-reveal-success")
    assert_equal "vessel_access_information.revealed", event.action
    assert_equal %w[marina_gate_code], event.changed_fields
    assert_not_includes event.attributes.to_json, value
    assert_not_includes event.attributes.to_json, "Synthetic unrevealed lockbox 8054"
  end

  test "service revocation denies the next reveal and preserves encrypted data" do
    @relationship.update!(active: false)

    assert_raises(Authorization::RestrictedVesselPolicy::AccessDenied) do
      VesselAccessInformation::Revealer.reveal!(
        vessel: @vessel,
        field: "marina_gate_code",
        actor: @admin,
        request_id: "restricted-reveal-denied"
      )
    end

    event = SecurityAuditEvent.find_by!(request_id: "restricted-reveal-denied")
    assert_equal "vessel_access_information.reveal_denied", event.action
    assert_equal "denied", event.outcome
    assert_equal %w[marina_gate_code], event.changed_fields
    assert_equal "Synthetic reveal gate 4512", @record.reload.restricted_field("marina_gate_code")
  end

  test "a denial audit failure does not replace the authorization error or log values" do
    @relationship.update!(active: false)
    original_record = SecurityAudit::Recorder.method(:record!)
    SecurityAudit::Recorder.define_singleton_method(:record!) do |**|
      raise ActiveRecord::StatementInvalid, "Synthetic reveal gate 4512 must not be logged"
    end

    output = StringIO.new
    original_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(output)
    begin
      error = assert_raises(Authorization::RestrictedVesselPolicy::AccessDenied) do
        VesselAccessInformation::Revealer.reveal!(
          vessel: @vessel,
          field: "marina_gate_code",
          actor: @admin
        )
      end
      assert_equal Authorization::ACCESS_DENIED_MESSAGE, error.message
    ensure
      Rails.logger = original_logger
    end

    assert_includes output.string,
      "Vessel access information reveal denial audit failed: ActiveRecord::StatementInvalid"
    assert_not_includes output.string, "4512"
  ensure
    SecurityAudit::Recorder.define_singleton_method(:record!, original_record) if original_record
  end
end
