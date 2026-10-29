require "test_helper"

class VesselAccessInformationPrivacyTest < ActionDispatch::IntegrationTest
  setup do
    @account = create_account(name: "Restricted Information Privacy Account")
    @account.create_managed_service_relationship!(active: true)
    @vessel = create_vessel(account: @account, name: "Privacy Test Vessel")
    @admin = create_user(email: "restricted-privacy-admin@example.test", role: "admin")
    @synthetic_secret = "Synthetic harbor key safe 5572"
    VesselAccessInformation::Persistence.save!(
      vessel: @vessel,
      restricted_details: @synthetic_secret,
      actor: @admin
    )
  end

  test "ordinary vessel reads forms attributes and search do not expose restricted details" do
    sign_in_as @admin

    get vessel_path(@vessel)
    assert_response :success
    assert_not_includes response.body, @synthetic_secret

    get edit_vessel_path(@vessel)
    assert_response :success
    assert_not_includes response.body, @synthetic_secret

    assert_not_includes @vessel.reload.attributes.values, @synthetic_secret
    assert_not Asset.search(@synthetic_secret).exists?
  end

  test "restricted detail parameters are filtered from logs" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter(
      vessel_access_information: {
        restricted_details: @synthetic_secret
      }
    )

    assert_equal "[FILTERED]", filtered.dig(:vessel_access_information, :restricted_details)
    assert_not_includes filtered.to_json, @synthetic_secret
  end
end
