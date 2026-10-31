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
    @vessel.documents.create!(
      account: @account,
      title: "Ordinary privacy document",
      document_type: "other"
    )
    sign_in_as @admin

    get vessel_path(@vessel)
    assert_response :success
    assert_not_includes response.body, @synthetic_secret

    get edit_vessel_path(@vessel)
    assert_response :success
    assert_not_includes response.body, @synthetic_secret

    get documents_path
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


  test "field-aware restricted parameters are filtered as one credential-bearing payload" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter(
      restricted_fields: {
        marina_gate_code: { operation: "replace", value: "Synthetic filtered gate 4208" },
        physical_key_location: { operation: "replace", value: "Synthetic filtered key location" }
      }
    )

    assert_equal "[FILTERED]", filtered.fetch(:restricted_fields)
    assert_not_includes filtered.to_json, "Synthetic filtered gate 4208"
    assert_not_includes filtered.to_json, "Synthetic filtered key location"
  end
end
