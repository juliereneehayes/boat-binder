require "test_helper"

class VesselAccessOperationsTest < ActionDispatch::IntegrationTest
  setup do
    @managed_account = create_account(name: "Access Operations Managed Account")
    @managed_relationship = @managed_account.create_managed_service_relationship!(active: true)
    @managed_vessel = create_vessel(account: @managed_account, name: "Access Operations Managed Vessel")
    @admin = create_user(email: "access-operations-admin@example.test", role: "admin")
    @gate_code = "Synthetic profile gate 4826"
    @lockbox_code = "Synthetic profile lockbox 1953"
  end

  test "managed service page masks restricted fields and reveals only the requested value with no-store" do
    VesselAccessInformation::Persistence.update_fields!(
      vessel: @managed_vessel,
      updates: {
        marina_gate_code: { operation: "replace", value: @gate_code },
        lockbox_code: { operation: "replace", value: @lockbox_code }
      },
      actor: @admin
    )
    sign_in_as @admin

    get vessel_path(@managed_vessel)

    assert_response :success
    assert_includes response.body, "Access &amp; Operations"
    assert_includes response.body, "Restricted Access"
    assert_not_includes response.body, @gate_code
    assert_not_includes response.body, @lockbox_code
    assert_select "input[type=hidden][value=?]", @gate_code, count: 0
    assert_select "input[type=hidden][value=?]", @lockbox_code, count: 0
    assert_select "turbo-frame#restricted_access_marina_gate_code" do
      assert_select "form[action=?]", reveal_vessel_access_information_path(@managed_vessel)
    end

    assert_difference -> { SecurityAuditEvent.where(action: "vessel_access_information.revealed").count }, 1 do
      post reveal_vessel_access_information_path(@managed_vessel), params: { field: "marina_gate_code" }
    end

    assert_response :success
    assert_includes response.headers.fetch("Cache-Control"), "no-store"
    assert_includes response.body, @gate_code
    assert_not_includes response.body, @lockbox_code
    assert_select "[data-restricted-reveal-target=secret]", text: @gate_code
    reveal_event = SecurityAuditEvent.order(:id).last
    assert_equal %w[marina_gate_code], reveal_event.changed_fields
    assert_not_includes reveal_event.attributes.to_json, @gate_code

    post hide_vessel_access_information_path(@managed_vessel), params: { field: "marina_gate_code" }

    assert_response :success
    assert_includes response.headers.fetch("Cache-Control"), "no-store"
    assert_not_includes response.body, @gate_code
    assert_includes response.body, "••••••••"
  end

  test "empty and partially completed sections render without creating placeholder restricted records" do
    sign_in_as @admin

    get vessel_path(@managed_vessel)
    assert_response :success
    assert_select "turbo-frame[id^=restricted_access_]", count: 6
    assert_select "turbo-frame[id^=restricted_access_]", text: /Not set/, count: 6
    assert_nil @managed_vessel.vessel_access_information

    patch vessel_access_information_path(@managed_vessel)
    assert_redirected_to vessel_path(@managed_vessel, anchor: "access-operations")
    assert_nil @managed_vessel.reload.vessel_access_information

    patch vessel_access_information_path(@managed_vessel), params: {
      restricted_fields: {
        marina_gate_code: { operation: "keep", value: "" },
        lockbox_code: { operation: "clear", value: "" }
      }
    }
    assert_redirected_to vessel_path(@managed_vessel, anchor: "access-operations")
    assert_nil @managed_vessel.reload.vessel_access_information

    patch vessel_access_information_path(@managed_vessel), params: {
      restricted_fields: {
        marina_access_instructions: { operation: "replace", value: "Synthetic call-box instructions" }
      }
    }
    follow_redirect!
    assert_response :success
    assert_includes response.body, "••••••••"
    assert_not_includes response.body, "Synthetic call-box instructions"
    assert_select "turbo-frame#restricted_access_marina_access_instructions form[action=?]",
      reveal_vessel_access_information_path(@managed_vessel)
  end

  test "authorized updates create replace keep and clear optional restricted fields" do
    sign_in_as @admin

    patch vessel_access_information_path(@managed_vessel), params: {
      restricted_fields: {
        marina_gate_code: { operation: "replace", value: @gate_code },
        lockbox_code: { operation: "replace", value: @lockbox_code },
        alarm_security_code: { operation: "keep", value: "" }
      }
    }

    assert_redirected_to vessel_path(@managed_vessel, anchor: "access-operations")
    record = @managed_vessel.reload.vessel_access_information
    assert_equal @gate_code, record.restricted_field("marina_gate_code")
    assert_equal @lockbox_code, record.restricted_field("lockbox_code")
    assert_nil record.restricted_field("alarm_security_code")

    patch vessel_access_information_path(@managed_vessel), params: {
      restricted_fields: {
        marina_gate_code: { operation: "keep", value: "" },
        lockbox_code: { operation: "replace", value: "Synthetic replacement lockbox 6670" },
        alarm_security_code: { operation: "replace", value: "" }
      }
    }

    assert_redirected_to vessel_path(@managed_vessel, anchor: "access-operations")
    record.reload
    assert_equal @gate_code, record.restricted_field("marina_gate_code")
    assert_equal @lockbox_code, record.restricted_field("lockbox_code"), "invalid replacement rolls back the request"
    assert_nil record.restricted_field("alarm_security_code")

    patch vessel_access_information_path(@managed_vessel), params: {
      restricted_fields: {
        marina_gate_code: { operation: "clear" },
        lockbox_code: { operation: "replace", value: "Synthetic replacement lockbox 6670" }
      }
    }

    record.reload
    assert_nil record.restricted_field("marina_gate_code")
    assert_equal "Synthetic replacement lockbox 6670", record.restricted_field("lockbox_code")
  end

  test "keep rejects a typed value and all keep accurately reports no changes" do
    VesselAccessInformation::Persistence.update_fields!(
      vessel: @managed_vessel,
      updates: { marina_gate_code: { operation: "replace", value: @gate_code } },
      actor: @admin
    )
    sign_in_as @admin
    audit_count = SecurityAuditEvent.count
    submitted_value = "Synthetic unselected replacement 6921"

    patch vessel_access_information_path(@managed_vessel), params: {
      restricted_fields: {
        marina_gate_code: { operation: "keep", value: submitted_value }
      }
    }
    follow_redirect!

    assert_response :success
    assert_includes response.body, "Remove the new value or choose Replace."
    assert_not_includes response.body, submitted_value
    assert_equal @gate_code,
      @managed_vessel.reload.vessel_access_information.restricted_field("marina_gate_code")
    assert_equal audit_count, SecurityAuditEvent.count

    patch vessel_access_information_path(@managed_vessel), params: {
      restricted_fields: {
        marina_gate_code: { operation: "keep", value: "" },
        lockbox_code: { operation: "keep", value: "" }
      }
    }
    follow_redirect!

    assert_includes response.body, "No restricted access changes were selected."
    assert_not_includes response.body, "Restricted access information updated."
    assert_equal audit_count, SecurityAuditEvent.count
  end

  test "unsupported payload versions fail safely in pages updates and reveals" do
    future_value = "Synthetic future payload gate 4730"
    future_payload = JSON.generate(
      "schema" => VesselAccessInformation::PAYLOAD_SCHEMA,
      "version" => VesselAccessInformation::PAYLOAD_VERSION + 1,
      "fields" => { "marina_gate_code" => future_value }
    )
    record = VesselAccessInformation::Persistence.save!(
      vessel: @managed_vessel,
      restricted_details: future_payload,
      actor: @admin
    )
    stored_before = VesselAccessInformation.connection.select_value(
      VesselAccessInformation.sanitize_sql_array(
        [ "SELECT restricted_details FROM vessel_access_information WHERE id = ?", record.id ]
      )
    )
    sign_in_as @admin
    audit_count = SecurityAuditEvent.count

    get vessel_path(@managed_vessel)
    assert_response :success
    assert_includes response.body, "uses a format this version cannot safely read"
    assert_not_includes response.body, future_value
    assert_select "form[action=?]", vessel_access_information_path(@managed_vessel), count: 0

    patch vessel_access_information_path(@managed_vessel), params: {
      restricted_fields: {
        lockbox_code: { operation: "replace", value: "Synthetic unsafe overwrite 3387" }
      }
    }
    follow_redirect!
    assert_includes response.body, "stored format is not supported"
    assert_not_includes response.body, future_value
    assert_not_includes response.body, "3387"

    post reveal_vessel_access_information_path(@managed_vessel), params: { field: "marina_gate_code" }
    assert_response :unprocessable_entity
    assert_includes response.body, "No value was revealed or changed."
    assert_not_includes response.body, future_value

    stored_after = VesselAccessInformation.connection.select_value(
      VesselAccessInformation.sanitize_sql_array(
        [ "SELECT restricted_details FROM vessel_access_information WHERE id = ?", record.id ]
      )
    )
    assert_equal stored_before, stored_after
    assert_equal future_payload, record.reload.restricted_details
    assert_equal audit_count, SecurityAuditEvent.count
  end

  test "self managed owner can maintain restricted fields while HYC staff cannot read or write them" do
    account = create_account(name: "Access Operations Self Managed Account")
    qualify_self_managed_subscription(account)
    vessel = create_vessel(account:, name: "Access Operations Self Managed Vessel")
    owner = create_user(email: "access-operations-owner@example.test", role: "owner")
    create_account_membership(user: owner, account:, access_level: "editor")
    sign_in_as owner

    patch vessel_access_information_path(vessel), params: {
      restricted_fields: {
        physical_key_location: { operation: "replace", value: "Synthetic key location in test locker" }
      }
    }
    assert_redirected_to vessel_path(vessel, anchor: "access-operations")

    post reveal_vessel_access_information_path(vessel), params: { field: "physical_key_location" }
    assert_response :success
    assert_includes response.body, "Synthetic key location in test locker"

    sign_in_as @admin
    get vessel_path(vessel)
    assert_response :success
    assert_includes response.body, "Restricted access information is not available"
    assert_not_includes response.body, "Synthetic key location in test locker"

    post reveal_vessel_access_information_path(vessel), params: { field: "physical_key_location" }
    assert_access_denied_redirect
    assert_not_includes response.body, "Synthetic key location in test locker"

    patch vessel_access_information_path(vessel), params: {
      restricted_fields: {
        physical_key_location: { operation: "replace", value: "Synthetic unauthorized replacement" }
      }
    }
    assert_access_denied_redirect
    assert_equal "Synthetic key location in test locker",
      vessel.reload.vessel_access_information.restricted_field("physical_key_location")
  end

  test "read-only managed service owner can reveal but cannot edit restricted or ordinary information" do
    reader = create_user(email: "access-operations-reader@example.test", role: "owner")
    create_account_membership(user: reader, account: @managed_account, access_level: "read_only")
    qualify_self_managed_subscription(@managed_account)
    VesselAccessInformation::Persistence.update_fields!(
      vessel: @managed_vessel,
      updates: { marina_gate_code: { operation: "replace", value: @gate_code } },
      actor: @admin
    )
    sign_in_as reader

    get vessel_path(@managed_vessel)
    assert_response :success
    assert_includes response.body, "Your current access is read-only"
    assert_select "form[action=?]", vessel_access_information_path(@managed_vessel), count: 0

    post reveal_vessel_access_information_path(@managed_vessel), params: { field: "marina_gate_code" }
    assert_response :success
    assert_includes response.body, @gate_code

    patch vessel_access_information_path(@managed_vessel), params: {
      restricted_fields: { marina_gate_code: { operation: "clear" } }
    }
    assert_access_denied_redirect
    assert_equal @gate_code,
      @managed_vessel.reload.vessel_access_information.restricted_field("marina_gate_code")

    patch vessel_path(@managed_vessel), params: {
      asset: { engine_startup_instructions: "Synthetic unauthorized routine edit" }
    }
    assert_access_denied_redirect
    assert_nil @managed_vessel.reload.engine_startup_instructions
  end

  test "managed service owner restricted endpoints remain independent of self managed billing" do
    owner = create_user(email: "access-operations-managed-editor@example.test", role: "owner")
    create_account_membership(user: owner, account: @managed_account, access_level: "editor")
    VesselAccessInformation::Persistence.update_fields!(
      vessel: @managed_vessel,
      updates: { marina_gate_code: { operation: "replace", value: @gate_code } },
      actor: @admin
    )
    sign_in_as owner

    post reveal_vessel_access_information_path(@managed_vessel), params: { field: "marina_gate_code" }
    assert_response :success
    assert_includes response.body, @gate_code

    patch vessel_access_information_path(@managed_vessel), params: {
      restricted_fields: {
        marina_gate_code: { operation: "replace", value: "Synthetic managed owner replacement 9042" }
      }
    }
    assert_redirected_to vessel_path(@managed_vessel, anchor: "access-operations")
    assert_equal "Synthetic managed owner replacement 9042",
      @managed_vessel.reload.vessel_access_information.restricted_field("marina_gate_code")
  end

  test "routine instructions follow ordinary Vessel access and render user text safely" do
    sign_in_as @admin
    unsafe_instruction = "Start blower. <script>alert('synthetic')</script>"

    patch vessel_path(@managed_vessel), params: {
      asset: {
        engine_startup_instructions: unsafe_instruction,
        engine_shutdown_instructions: "Synthetic shutdown sequence",
        battery_shore_power_instructions: "Synthetic shore-power sequence",
        operating_notes: "Synthetic ordinary operating note"
      }
    }

    assert_redirected_to vessel_path(@managed_vessel.reload)
    assert_equal unsafe_instruction, @managed_vessel.engine_startup_instructions

    get vessel_path(@managed_vessel)
    assert_response :success
    assert_includes response.body, "Start blower."
    assert_includes response.body, "&lt;script&gt;alert(&#39;synthetic&#39;)&lt;/script&gt;"
    assert_not_includes response.body, "<script>alert('synthetic')</script>"
    assert_includes response.body, "Synthetic shutdown sequence"
  end

  test "revocation inactive accounts and cross-account IDs are enforced on each restricted request" do
    VesselAccessInformation::Persistence.update_fields!(
      vessel: @managed_vessel,
      updates: { marina_gate_code: { operation: "replace", value: @gate_code } },
      actor: @admin
    )
    sign_in_as @admin
    @managed_relationship.update!(active: false)

    post reveal_vessel_access_information_path(@managed_vessel), params: { field: "marina_gate_code" }
    assert_access_denied_redirect
    assert_not_includes response.body, @gate_code

    @managed_relationship.update!(active: true)
    @managed_account.update!(active: false)
    post reveal_vessel_access_information_path(@managed_vessel), params: { field: "marina_gate_code" }
    assert_access_denied_redirect

    other_account = create_account(name: "Access Operations Cross Account")
    qualify_self_managed_subscription(other_account)
    other_owner = create_user(email: "access-operations-cross-account@example.test", role: "owner")
    create_account_membership(user: other_owner, account: other_account, access_level: "editor")
    sign_in_as other_owner

    post reveal_vessel_access_information_path(@managed_vessel), params: { field: "marina_gate_code" }
    assert_response :not_found
    assert_not_includes response.body, @gate_code
  end
end
