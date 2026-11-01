require "test_helper"
require Rails.root.join("db/migrate/20261031120000_add_vessel_operating_instructions")

class AddVesselOperatingInstructionsTest < ActiveSupport::TestCase
  test "rollback preserves populated ordinary operating instructions and encrypted records" do
    account = create_account(name: "Operating Instructions Rollback Account")
    account.create_managed_service_relationship!(active: true)
    vessel = create_vessel(account:, name: "Operating Instructions Rollback Vessel")
    vessel.update!(engine_startup_instructions: "Synthetic retained startup instructions")
    actor = create_user(email: "operating-rollback@example.test", role: "admin")
    record = VesselAccessInformation::Persistence.update_fields!(
      vessel:,
      updates: { marina_gate_code: { operation: "replace", value: "Synthetic retained gate 2704" } },
      actor:
    )

    migration = AddVesselOperatingInstructions.new
    error = assert_raises(ActiveRecord::IrreversibleMigration) do
      migration.suppress_messages { migration.down }
    end

    assert_includes error.message, "leave the additive columns in place"
    assert_equal "Synthetic retained startup instructions", vessel.reload.engine_startup_instructions
    assert_equal "Synthetic retained gate 2704", record.reload.restricted_field("marina_gate_code")
  end
end
