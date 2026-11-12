require "application_system_test_case"

class ServiceVisitBatteryManagementTest < ApplicationSystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1200, 900 ]

  setup do
    @user = create_user(email: "battery-workflow@example.test")
    @account = create_account(name: "Battery Workflow Account")
    @vessel = create_vessel(account: @account, name: "Battery Workflow Vessel")
  end

  test "captain adds and edits a battery without disturbing an unsaved visit or selected photo" do
    sign_in_with_browser(@user)
    visit new_vessel_service_visit_path(@vessel)

    fill_in "Location", with: "Port side"
    fill_in "Port Engine Hours", with: "145.6"
    check "Hull"
    fill_in "Optional note for hull", with: "Check the new seal"
    fill_in "Owner summary", with: "Unsaved summary"
    attach_file "Choose or take photos", file_fixture("sample.jpg")
    assert_equal 1, selected_visit_photo_count
    preview_src = selected_visit_photo_preview_src
    assert_selected_visit_photo_preview(preview_src)

    click_link "Add battery"
    within "#service_visit_battery_management" do
      fill_in "Battery name", with: "House Bank"
      fill_in "Location", with: "Aft locker"
      assert_equal "House Bank", find_field("Battery name").value
      assert_equal "Aft locker", find_field("Location").value
      click_button "Add battery"
    end

    assert_current_path new_vessel_service_visit_path(@vessel)
    assert_no_text "Name can't be blank"
    assert_selector "#service_visit_battery_checks"
    battery = @vessel.asset_batteries.find_by!(name: "House Bank")
    assert_selector "#service_visit_battery_#{battery.id}_name", text: "House Bank"
    assert_equal "Port side", find_field("Location").value
    assert_equal "145.6", find_field("Port Engine Hours").value
    assert_checked_field "Hull"
    assert_equal "Check the new seal", find_field("Optional note for hull").value
    assert_equal "Unsaved summary", find_field("Owner summary").value
    assert_equal 1, selected_visit_photo_count
    assert_selected_visit_photo_preview(preview_src)
    assert_equal 0, @vessel.service_visits.count

    check "House Bank"
    fill_in "service_visit_battery_checks_#{battery.id}_voltage", with: "12.64"
    fill_in "service_visit_battery_checks_#{battery.id}_notes", with: "Stable"
    click_link "Edit battery"
    within "#service_visit_battery_management" do
      fill_in "Battery name", with: "House Bank Updated"
      fill_in "Location", with: "Engine room"
      click_button "Save battery"
    end

    assert_selector "#service_visit_battery_#{battery.id}_name", text: "House Bank Updated"
    assert_equal "12.64", find_field("service_visit_battery_checks_#{battery.id}_voltage").value
    assert_equal "Stable", find_field("service_visit_battery_checks_#{battery.id}_notes").value
    assert_equal "Unsaved summary", find_field("Owner summary").value
    assert_equal 1, selected_visit_photo_count
    assert_selected_visit_photo_preview(preview_src)
    assert_equal 0, @vessel.service_visits.count

    check "House Bank Updated"
    click_button "Save visit report"

    assert_text "Visit report saved."
    assert_equal 1, @vessel.service_visits.count
    service_visit = @vessel.service_visits.order(:id).last
    assert_current_path vessel_service_visit_path(@vessel, service_visit)
    battery_check = service_visit.service_visit_battery_checks.find_by!(asset_battery: battery)
    assert battery_check.checked?
    assert_equal 12.64.to_d, battery_check.voltage
    assert_equal "Stable", battery_check.notes
    service_visit.reload
    assert_equal "Unsaved summary", service_visit.summary
  end

  test "battery validation errors and cancel preserve the unsaved visit form and photo" do
    sign_in_with_browser(@user)
    visit new_vessel_service_visit_path(@vessel)
    fill_in "Owner summary", with: "Still here"
    attach_file "Choose or take photos", file_fixture("sample.jpg")
    preview_src = selected_visit_photo_preview_src
    assert_selected_visit_photo_preview(preview_src)

    click_link "Add battery"
    within "#service_visit_battery_management" do
      click_button "Add battery"
    end

    assert_text "Name can't be blank"
    assert_equal "Still here", find_field("Owner summary").value
    assert_equal 1, selected_visit_photo_count
    assert_selected_visit_photo_preview(preview_src)

    click_link "Cancel"
    assert_selector "#service_visit_battery_management[hidden]", visible: :all
    assert_equal "Still here", find_field("Owner summary").value
    assert_equal 1, selected_visit_photo_count
    assert_selected_visit_photo_preview(preview_src)

    click_link "Add battery"
    within "#service_visit_battery_management" do
      fill_in "Battery name", with: "Reopened Battery"
      click_button "Add battery"
    end

    assert_no_text "Name can't be blank"
    battery = @vessel.asset_batteries.find_by!(name: "Reopened Battery")
    assert_selector "#service_visit_battery_#{battery.id}_name", text: "Reopened Battery"
    assert_equal "Still here", find_field("Owner summary").value
    assert_equal 1, selected_visit_photo_count
    assert_selected_visit_photo_preview(preview_src)
    assert_equal 0, @vessel.service_visits.count
  end

  test "editing a battery from an existing visit edit preserves unsaved visit changes" do
    battery = create_battery(asset: @vessel, name: "Starter Bank")
    service_visit = @vessel.service_visits.new(performed_by_user: @user, visit_date: Date.current, summary: "Saved summary")
    service_visit.build_workflow_defaults
    service_visit.save!

    sign_in_with_browser(@user)
    visit edit_vessel_service_visit_path(@vessel, service_visit)
    fill_in "Owner summary", with: "Unsaved edit summary"
    fill_in "service_visit_battery_checks_#{battery.id}_voltage", with: "12.51"
    within "#service_visit_battery_check_#{battery.id}" do
      click_link "Edit battery"
    end
    within "#service_visit_battery_management" do
      fill_in "Battery name", with: "Starter Bank Updated"
      click_button "Save battery"
    end

    assert_selector "#service_visit_battery_#{battery.id}_name", text: "Starter Bank Updated"
    assert_equal "Unsaved edit summary", find_field("Owner summary").value
    assert_equal "12.51", find_field("service_visit_battery_checks_#{battery.id}_voltage").value

    click_link "Add battery"
    within "#service_visit_battery_management" do
      fill_in "Battery name", with: "New Visit Battery"
      click_button "Add battery"
    end
    new_battery = @vessel.asset_batteries.find_by!(name: "New Visit Battery")
    check "New Visit Battery"
    fill_in "service_visit_battery_checks_#{new_battery.id}_voltage", with: "12.83"
    fill_in "service_visit_battery_checks_#{new_battery.id}_notes", with: "Installed inline"
    click_button "Save visit changes"

    assert_text "Visit report updated."
    assert_current_path vessel_service_visit_path(@vessel, service_visit)
    service_visit.reload
    new_check = service_visit.service_visit_battery_checks.find_by!(asset_battery: new_battery)
    assert new_check.checked?
    assert_equal 12.83.to_d, new_check.voltage
    assert_equal "Installed inline", new_check.notes
    assert_equal 1, @vessel.service_visits.count
  end

  test "full page battery management remains usable without a Turbo Frame" do
    sign_in_with_browser(@user)
    visit new_vessel_battery_path(@vessel, from_service_visit: 1)

    assert_link "Back to #{@vessel.name}"
    assert_no_link "Cancel"
    click_button "Add battery"
    assert_text "Name can't be blank"
    assert_link "Back to #{@vessel.name}"
    fill_in "Battery name", with: "Full Page Battery"
    click_button "Add battery"

    assert_text "Battery added."
    assert_current_path vessel_path(@vessel)
    assert_includes page.current_url, "#batteries"
    assert_no_text "turbo-stream"
  end

  private

  def selected_visit_photo_count
    page.evaluate_script("document.querySelector('#service_visit_photos').files.length")
  end

  def selected_visit_photo_preview_src
    find("#service-visit-photos-upload-preview img[data-upload-preview-local]")["src"]
  end

  def assert_selected_visit_photo_preview(src)
    selector = "#service-visit-photos-upload-preview img[data-upload-preview-local]"
    assert_selector selector, visible: true
    assert_equal src, selected_visit_photo_preview_src
    assert page.evaluate_async_script(<<~JAVASCRIPT)
      const done = arguments[0]
      const image = document.querySelector("#{selector}")
      if (!image) return done(false)
      if (image.complete) return done(image.naturalWidth > 0)
      image.addEventListener("load", () => done(image.naturalWidth > 0), { once: true })
      image.addEventListener("error", () => done(false), { once: true })
    JAVASCRIPT
  end
end
