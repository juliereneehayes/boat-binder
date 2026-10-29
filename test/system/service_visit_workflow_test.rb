require "application_system_test_case"

class ServiceVisitWorkflowTest < ApplicationSystemTestCase
  setup do
    @user = create_user(email: "captain@hayesyacht.test")
    @account = create_account(name: "Elliott Family")
    @account.contacts.create!(name: "Avery Elliott", email: "avery@example.test", role: "Owner")
    @vessel = create_vessel(account: @account)
    @vessel.reminders.create!(title: "Replace zincs", due_date: Date.current + 3.days, reminder_type: "maintenance")
  end

  test "captain records a visit and sees the owner report" do
    sign_in_with_browser(@user)

    assert_text "Captain Dashboard"
    within("aside.fixed") { click_on "Vessels" }
    click_on @vessel.name
    click_on "Start Visit"

    fill_in "Port Engine Hours", with: "128.7"
    fill_in "Starboard Engine Hours", with: "129.1"
    fill_in "Owner summary", with: "Routine check complete and vessel is ready for owner use."
    fill_in "General condition notes", with: "Bilge dry, shore power connected, dock lines secure."
    check "Follow-up needed"
    fill_in "Follow up notes", with: "Replace forward spring line."
    click_on "Save visit report"

    assert_text "Visit report saved."
    assert_text "#{@vessel.name} Visit Report"
    assert_text "128.7"
    assert_text "129.1"
    assert_text "Replace forward spring line."
  end
end
