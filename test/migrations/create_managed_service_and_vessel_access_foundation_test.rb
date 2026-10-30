require "test_helper"
require Rails.root.join("db/migrate/20261029120000_create_managed_service_and_vessel_access_foundation")

class CreateManagedServiceAndVesselAccessFoundationTest < ActiveSupport::TestCase
  test "rollback preserves managed service and encrypted vessel access records" do
    account = create_account(name: "Foundation Rollback Account")
    relationship = account.create_managed_service_relationship!(active: true)
    vessel = create_vessel(account:, name: "Foundation Rollback Vessel")
    actor = create_user(email: "foundation-rollback@example.test", role: "admin")
    record = VesselAccessInformation::Persistence.save!(
      vessel:,
      restricted_details: "Synthetic rollback preservation code 7019",
      actor:
    )

    migration = CreateManagedServiceAndVesselAccessFoundation.new
    error = assert_raises(ActiveRecord::IrreversibleMigration) do
      migration.suppress_messages { migration.down }
    end

    assert_includes error.message, "leave the additive tables in place"
    assert VesselAccessInformation.exists?(record.id)
    assert ManagedServiceRelationship.exists?(relationship.id)
    assert ActiveRecord::Base.connection.table_exists?(:managed_service_relationships)
  end
end
