require "application_system_test_case"

class VesselBatteryNavigationTest < ApplicationSystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1200, 900 ]

  test "creating and editing a battery returns to the vessel batteries section" do
    user = create_user(email: "vessel-battery-navigation@example.test")
    vessel = create_vessel

    sign_in_with_browser(user)
    visit vessel_path(vessel)

    click_link "Add battery"
    fill_in "Battery name", with: "House Battery"
    click_button "Add battery"

    assert_batteries_section_navigation(vessel)

    click_link "Edit", match: :first
    fill_in "Battery name", with: "Updated House Battery"
    click_button "Save battery"

    assert_batteries_section_navigation(vessel)
    assert_text "Updated House Battery"
  end

  private

  def assert_batteries_section_navigation(vessel)
    assert_current_path vessel_path(vessel, anchor: "batteries")
    assert_equal "#batteries", page.evaluate_script("window.location.hash")

    section_position = page.evaluate_script("document.getElementById('batteries').getBoundingClientRect()")
    viewport_height = page.evaluate_script("window.innerHeight")
    assert_operator section_position.fetch("top"), :<, viewport_height
    assert_operator section_position.fetch("bottom"), :>, 0
  end
end
