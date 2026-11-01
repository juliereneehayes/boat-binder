require "test_helper"

class VesselAccessInformation::PersistenceTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @account = create_account(name: "Audited Vessel Access Account")
    @account.create_managed_service_relationship!(active: true)
    @vessel = create_vessel(account: @account, name: "Audited Vessel")
    @actor = create_user(email: "vessel-access-auditor@example.test", role: "admin")
    @synthetic_secret = "Synthetic marina lockbox 7281"
  end

  test "create and update are audited with field names but no restricted value" do
    assert_no_enqueued_jobs do
      assert_difference -> { SecurityAuditEvent.count }, 1 do
        @record = VesselAccessInformation::Persistence.save!(
          vessel: @vessel,
          restricted_details: @synthetic_secret,
          actor: @actor,
          request_id: "restricted-create-request"
        )
      end
    end

    create_event = SecurityAuditEvent.order(:id).last
    assert_equal "vessel_access_information.created", create_event.action
    assert_equal @actor, create_event.actor_user
    assert_equal @account, create_event.account
    assert_equal "VesselAccessInformation", create_event.target_type
    assert_equal @record.id, create_event.target_id
    assert_equal %w[restricted_details], create_event.changed_fields
    assert_nil create_event.source_ip
    assert_not_includes create_event.attributes.to_json, @synthetic_secret

    replacement = "Synthetic marina lockbox 9146"
    assert_difference -> { SecurityAuditEvent.count }, 1 do
      VesselAccessInformation::Persistence.save!(
        vessel: @vessel,
        restricted_details: replacement,
        actor: @actor,
        request_id: "restricted-update-request"
      )
    end

    update_event = SecurityAuditEvent.order(:id).last
    assert_equal "vessel_access_information.updated", update_event.action
    assert_equal %w[restricted_details], update_event.changed_fields
    assert_not_includes update_event.attributes.to_json, @synthetic_secret
    assert_not_includes update_event.attributes.to_json, replacement
  end

  test "unchanged details do not create a duplicate audit event" do
    VesselAccessInformation::Persistence.save!(
      vessel: @vessel,
      restricted_details: @synthetic_secret,
      actor: @actor
    )

    assert_no_difference -> { SecurityAuditEvent.count } do
      VesselAccessInformation::Persistence.save!(
        vessel: @vessel,
        restricted_details: @synthetic_secret,
        actor: @actor
      )
    end
  end

  test "nil and blank new details fail validation instead of returning an unsaved record" do
    [ nil, "", "   " ].each do |invalid_details|
      error = assert_raises(ActiveRecord::RecordInvalid) do
        VesselAccessInformation::Persistence.save!(
          vessel: @vessel,
          restricted_details: invalid_details,
          actor: @actor
        )
      end

      assert_includes error.record.errors[:restricted_details], "can't be blank"
      assert_equal 0, VesselAccessInformation.count
      assert_equal 0, SecurityAuditEvent.count
    end
  end

  test "length boundary succeeds and an oversized update preserves the encrypted record" do
    maximum = "a" * VesselAccessInformation::MAX_RESTRICTED_DETAILS_LENGTH
    record = VesselAccessInformation::Persistence.save!(
      vessel: @vessel,
      restricted_details: maximum,
      actor: @actor
    )

    oversized = "b" * (VesselAccessInformation::MAX_RESTRICTED_DETAILS_LENGTH + 1)
    error = assert_raises(ActiveRecord::RecordInvalid) do
      VesselAccessInformation::Persistence.save!(
        vessel: @vessel,
        restricted_details: oversized,
        actor: @actor
      )
    end

    assert_includes error.record.errors[:restricted_details],
      "is too long (maximum is #{VesselAccessInformation::MAX_RESTRICTED_DETAILS_LENGTH} characters)"
    assert_equal maximum, record.reload.restricted_details
    assert_equal 1, SecurityAuditEvent.count
  end

  test "field updates preserve untouched values and audit only semantic field names" do
    record = VesselAccessInformation::Persistence.update_fields!(
      vessel: @vessel,
      updates: {
        marina_gate_code: { operation: "replace", value: "Synthetic gate 1204" },
        lockbox_code: { operation: "replace", value: "Synthetic lockbox 7721" }
      },
      actor: @actor,
      request_id: "restricted-field-create"
    )

    assert_equal "Synthetic gate 1204", record.restricted_field("marina_gate_code")
    assert_equal "Synthetic lockbox 7721", record.restricted_field("lockbox_code")
    create_event = SecurityAuditEvent.find_by!(request_id: "restricted-field-create")
    assert_equal "vessel_access_information.created", create_event.action
    assert_equal %w[lockbox_code marina_gate_code], create_event.changed_fields

    VesselAccessInformation::Persistence.update_fields!(
      vessel: @vessel,
      updates: {
        marina_gate_code: { operation: "keep", value: "" },
        lockbox_code: { operation: "replace", value: "Synthetic lockbox 8842" }
      },
      actor: @actor,
      request_id: "restricted-field-update"
    )

    record.reload
    assert_equal "Synthetic gate 1204", record.restricted_field("marina_gate_code")
    assert_equal "Synthetic lockbox 8842", record.restricted_field("lockbox_code")
    update_event = SecurityAuditEvent.find_by!(request_id: "restricted-field-update")
    assert_equal "vessel_access_information.updated", update_event.action
    assert_equal %w[lockbox_code], update_event.changed_fields
    assert_not_includes update_event.attributes.to_json, "8842"
  end

  test "keep with a submitted value fails without changing data or recording success" do
    record = VesselAccessInformation::Persistence.update_fields!(
      vessel: @vessel,
      updates: { marina_gate_code: { operation: "replace", value: "Synthetic gate 1204" } },
      actor: @actor
    )
    audit_count = SecurityAuditEvent.count

    error = assert_raises(VesselAccessInformation::Persistence::InvalidUpdate) do
      VesselAccessInformation::Persistence.update_fields!(
        vessel: @vessel,
        updates: { marina_gate_code: { operation: "keep", value: "Synthetic unselected gate 9192" } },
        actor: @actor
      )
    end

    assert_equal "Remove the new value or choose Replace.", error.message
    assert_not_includes error.message, "9192"
    assert_equal "Synthetic gate 1204", record.reload.restricted_field("marina_gate_code")
    assert_equal audit_count, SecurityAuditEvent.count
  end

  test "clearing fields is explicit and deleting the final empty record is audited" do
    record = VesselAccessInformation::Persistence.update_fields!(
      vessel: @vessel,
      updates: {
        marina_gate_code: { operation: "replace", value: "Synthetic gate 4102" },
        lockbox_code: { operation: "replace", value: "Synthetic lockbox 1008" }
      },
      actor: @actor
    )

    VesselAccessInformation::Persistence.update_fields!(
      vessel: @vessel,
      updates: {
        marina_gate_code: { operation: "clear", value: "Synthetic ignored clear value" }
      },
      actor: @actor,
      request_id: "restricted-field-clear-one"
    )

    assert_nil record.reload.restricted_field("marina_gate_code")
    assert_equal "Synthetic lockbox 1008", record.restricted_field("lockbox_code")
    clear_event = SecurityAuditEvent.find_by!(request_id: "restricted-field-clear-one")
    assert_equal "vessel_access_information.fields_cleared", clear_event.action
    assert_equal %w[marina_gate_code], clear_event.changed_fields
    assert_not_includes clear_event.attributes.to_json, "Synthetic"

    result = nil
    assert_difference -> { VesselAccessInformation.count }, -1 do
      result = VesselAccessInformation::Persistence.update_fields_with_result!(
        vessel: @vessel,
        updates: { lockbox_code: { operation: "clear" } },
        actor: @actor,
        request_id: "restricted-field-clear-final"
      )
    end

    final_event = SecurityAuditEvent.find_by!(request_id: "restricted-field-clear-final")
    assert_equal "vessel_access_information.fields_cleared", final_event.action
    assert_equal record.id, final_event.target_id
    assert result.changed
    assert_nil result.record
  end

  test "mutation result distinguishes actual changes from idempotent requests" do
    record = VesselAccessInformation::Persistence.update_fields!(
      vessel: @vessel,
      updates: { marina_gate_code: { operation: "replace", value: "Synthetic gate 5072" } },
      actor: @actor
    )
    audit_count = SecurityAuditEvent.count

    result = VesselAccessInformation::Persistence.update_fields_with_result!(
      vessel: @vessel,
      updates: {
        marina_gate_code: { operation: "replace", value: "Synthetic gate 5072" },
        lockbox_code: { operation: "clear" }
      },
      actor: @actor
    )

    assert_not result.changed
    assert_equal record, result.record
    assert_equal audit_count, SecurityAuditEvent.count
    assert_equal "Synthetic gate 5072", record.reload.restricted_field("marina_gate_code")
  end

  test "blank replacement and invalid operations preserve existing values" do
    record = VesselAccessInformation::Persistence.update_fields!(
      vessel: @vessel,
      updates: { marina_gate_code: { operation: "replace", value: "Synthetic gate 6120" } },
      actor: @actor
    )

    error = assert_raises(ActiveRecord::RecordInvalid) do
      VesselAccessInformation::Persistence.update_fields!(
        vessel: @vessel,
        updates: { marina_gate_code: { operation: "replace", value: "" } },
        actor: @actor
      )
    end
    assert_includes error.record.errors[:marina_gate_code], "must be provided when Replace is selected"

    assert_raises(VesselAccessInformation::Persistence::InvalidUpdate) do
      VesselAccessInformation::Persistence.update_fields!(
        vessel: @vessel,
        updates: { marina_gate_code: { operation: "transfer", value: "Synthetic transfer" } },
        actor: @actor
      )
    end
    assert_equal "Synthetic gate 6120", record.reload.restricted_field("marina_gate_code")
  end

  test "legacy restricted details are preserved during the first field update" do
    record = VesselAccessInformation::Persistence.save!(
      vessel: @vessel,
      restricted_details: @synthetic_secret,
      actor: @actor
    )

    VesselAccessInformation::Persistence.update_fields!(
      vessel: @vessel,
      updates: { lockbox_code: { operation: "replace", value: "Synthetic lockbox 7305" } },
      actor: @actor
    )

    assert_equal @synthetic_secret, record.reload.restricted_field("additional_vessel_access_notes")
    assert_equal "Synthetic lockbox 7305", record.restricted_field("lockbox_code")
  end

  test "maximum legacy details remain intact when another field is added" do
    legacy_details = " #{"\u0001" * (VesselAccessInformation::MAX_RESTRICTED_DETAILS_LENGTH - 2)}\n"
    record = VesselAccessInformation::Persistence.save!(
      vessel: @vessel,
      restricted_details: legacy_details,
      actor: @actor
    )

    VesselAccessInformation::Persistence.update_fields!(
      vessel: @vessel,
      updates: { marina_gate_code: { operation: "replace", value: "Synthetic gate 4380" } },
      actor: @actor
    )

    assert_equal legacy_details, record.reload.restricted_field("additional_vessel_access_notes")
    assert_equal "Synthetic gate 4380", record.restricted_field("marina_gate_code")
    assert_operator record.restricted_details.length, :<=, VesselAccessInformation::MAX_SERIALIZED_PAYLOAD_LENGTH

    VesselAccessInformation::Persistence.update_fields!(
      vessel: @vessel,
      updates: { lockbox_code: { operation: "replace", value: "Synthetic lockbox 1058" } },
      actor: @actor
    )

    assert_equal legacy_details, record.reload.restricted_field("additional_vessel_access_notes")
    assert_equal "Synthetic lockbox 1058", record.restricted_field("lockbox_code")
  end


  test "valid maximum field combinations persist despite JSON escaping overhead" do
    fields = VesselAccessInformation::RESTRICTED_FIELD_DEFINITIONS.to_h do |field, definition|
      [ field, "\u0001" * definition.fetch(:maximum) ]
    end

    record = VesselAccessInformation::Persistence.update_fields!(
      vessel: @vessel,
      updates: fields.transform_values { |value| { operation: "replace", value: } },
      actor: @actor
    )

    assert_operator record.restricted_details.length, :>, VesselAccessInformation::MAX_RESTRICTED_DETAILS_LENGTH
    assert_operator record.restricted_details.length, :<=, VesselAccessInformation::MAX_SERIALIZED_PAYLOAD_LENGTH
    assert_equal fields, record.reload.restricted_fields
  end

  test "unsupported stored payload versions preserve ciphertext and do not audit an update" do
    future_payload = JSON.generate(
      "schema" => VesselAccessInformation::PAYLOAD_SCHEMA,
      "version" => VesselAccessInformation::PAYLOAD_VERSION + 1,
      "fields" => { "marina_gate_code" => "Synthetic future gate 8026" }
    )
    record = VesselAccessInformation::Persistence.save!(
      vessel: @vessel,
      restricted_details: future_payload,
      actor: @actor
    )
    stored_before = raw_restricted_details(record)
    audit_count = SecurityAuditEvent.count

    assert_raises(VesselAccessInformation::UnsupportedPayloadVersion) do
      VesselAccessInformation::Persistence.update_fields!(
        vessel: @vessel,
        updates: { lockbox_code: { operation: "replace", value: "Synthetic replacement 1360" } },
        actor: @actor
      )
    end

    assert_equal stored_before, raw_restricted_details(record)
    assert_equal future_payload, record.reload.restricted_details
    assert_equal audit_count, SecurityAuditEvent.count
  end

  private

  def raw_restricted_details(record)
    VesselAccessInformation.connection.select_value(
      VesselAccessInformation.sanitize_sql_array(
        [ "SELECT restricted_details FROM vessel_access_information WHERE id = ?", record.id ]
      )
    )
  end
end
