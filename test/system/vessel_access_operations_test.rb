require "application_system_test_case"

class VesselAccessOperationsTest < ApplicationSystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 390, 844 ]

  test "authorized user safely reveals hides and replaces a restricted value on mobile" do
    account = create_account(name: "Mobile Access Operations Account")
    account.create_managed_service_relationship!(active: true)
    qualify_self_managed_subscription(account)
    vessel = create_vessel(account:, name: "Mobile Access Operations Vessel")
    owner = create_user(email: "mobile-access-operations@example.test", role: "owner")
    create_account_membership(user: owner, account:, access_level: "editor")
    original_code = "Synthetic mobile gate 3091"
    replacement_code = "Synthetic mobile gate 7450"
    VesselAccessInformation::Persistence.update_fields!(
      vessel:,
      updates: { marina_gate_code: { operation: "replace", value: original_code } },
      actor: owner
    )
    sign_in_with_browser(owner)

    visit vessel_path(vessel)
    assert_text "Access & Operations"
    assert_no_text original_code

    within("turbo-frame#restricted_access_marina_gate_code") do
      click_button "Reveal"
      assert_text original_code
      click_button "Hide"
      assert_no_text original_code
      assert_text "••••••••"
    end

    select "Replace", from: "restricted_fields_marina_gate_code_operation"
    fill_in "restricted_fields_marina_gate_code_value", with: replacement_code
    click_button "Save restricted access"

    assert_current_path vessel_path(vessel)
    assert_text "Restricted access information updated."
    assert_no_text replacement_code
    within("turbo-frame#restricted_access_marina_gate_code") do
      click_button "Reveal"
      assert_text replacement_code
      assert_no_text original_code
    end
  end
end
