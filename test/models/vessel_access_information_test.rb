require "test_helper"

class VesselAccessInformationTest < ActiveSupport::TestCase
  setup do
    @account = create_account(name: "Encrypted Vessel Account")
    @account.create_managed_service_relationship!(active: true)
    @vessel = create_vessel(account: @account, name: "Encrypted Vessel")
    @actor = create_user(email: "restricted-information-actor@example.test", role: "admin")
    @synthetic_secret = "Synthetic dock gate code 4938"
  end

  test "restricted details are encrypted at rest and decrypt through the model" do
    record = VesselAccessInformation::Persistence.save!(
      vessel: @vessel,
      restricted_details: @synthetic_secret,
      actor: @actor
    )

    stored_value = VesselAccessInformation.connection.select_value(
      VesselAccessInformation.sanitize_sql_array(
        [ "SELECT restricted_details FROM vessel_access_information WHERE id = ?", record.id ]
      )
    )

    assert_not_equal @synthetic_secret, stored_value
    assert_not_includes stored_value, @synthetic_secret
    assert_equal @synthetic_secret, record.reload.restricted_details
    assert_not_includes record.inspect, @synthetic_secret
  end

  test "only vessels can own restricted information" do
    home = create_asset(account: @account, asset_type: "home", name: "Shore House")
    record = VesselAccessInformation.new(vessel: home, restricted_details: @synthetic_secret)

    assert_not record.valid?
    assert_includes record.errors[:vessel], "must be a Vessel"
  end

  test "vessel and account context are derived without copying identifiers" do
    record = VesselAccessInformation::Persistence.save!(
      vessel: @vessel,
      restricted_details: @synthetic_secret,
      actor: @actor
    )

    assert_equal @vessel, record.vessel
    assert_equal @account, record.account
    assert_not_includes VesselAccessInformation.column_names, "account_id"
  end

  test "field payload preserves optional values and legacy representative details" do
    payload = VesselAccessInformation.serialize_fields(
      "marina_gate_code" => "Synthetic gate 1842",
      "lockbox_code" => "Synthetic lockbox 9910",
      "physical_key_location" => ""
    )

    assert_equal({
      "lockbox_code" => "Synthetic lockbox 9910",
      "marina_gate_code" => "Synthetic gate 1842"
    }, VesselAccessInformation.deserialize_fields(payload))
    assert_equal({
      "additional_vessel_access_notes" => @synthetic_secret
    }, VesselAccessInformation.deserialize_fields(@synthetic_secret))
  end

  test "field-aware payload remains encrypted at rest" do
    record = VesselAccessInformation::Persistence.update_fields!(
      vessel: @vessel,
      updates: {
        marina_gate_code: { operation: "replace", value: "Synthetic encrypted gate 2468" },
        lockbox_code: { operation: "replace", value: "Synthetic encrypted lockbox 1357" }
      },
      actor: @actor
    )

    stored_value = VesselAccessInformation.connection.select_value(
      VesselAccessInformation.sanitize_sql_array(
        [ "SELECT restricted_details FROM vessel_access_information WHERE id = ?", record.id ]
      )
    )

    assert_not_includes stored_value, "Synthetic encrypted gate 2468"
    assert_not_includes stored_value, "Synthetic encrypted lockbox 1357"
    assert_equal "Synthetic encrypted gate 2468", record.reload.restricted_field("marina_gate_code")
  end

  test "versioned payload preserves unknown future fields without exposing them" do
    payload = JSON.generate(
      "schema" => VesselAccessInformation::PAYLOAD_SCHEMA,
      "version" => VesselAccessInformation::PAYLOAD_VERSION,
      "fields" => {
        "marina_gate_code" => "Synthetic known gate 3852",
        "future_restricted_field" => "Synthetic future value"
      }
    )
    record = VesselAccessInformation::Persistence.save!(
      vessel: @vessel,
      restricted_details: payload,
      actor: @actor
    )

    VesselAccessInformation::Persistence.update_fields!(
      vessel: @vessel,
      updates: { lockbox_code: { operation: "replace", value: "Synthetic lockbox 9260" } },
      actor: @actor
    )

    fields = record.reload.restricted_fields
    assert_equal "Synthetic future value", fields.fetch("future_restricted_field")
    assert_nil record.restricted_field("future_restricted_field")
    assert_not_includes record.restricted_field_names, "future_restricted_field"
  end

  test "legacy JSON-shaped text cannot collide with the field payload format" do
    legacy_json = JSON.generate(
      "version" => VesselAccessInformation::PAYLOAD_VERSION,
      "fields" => { "marina_gate_code" => "Synthetic legacy JSON gate 5720" }
    )

    assert_equal({
      "additional_vessel_access_notes" => legacy_json
    }, VesselAccessInformation.deserialize_fields(legacy_json))
  end
end
