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
end
