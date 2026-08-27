require "test_helper"

class AccountTimeZoneTest < ActionDispatch::IntegrationTest
  setup do
    ActionMailer::Base.deliveries.clear
  end

  teardown do
    ActionMailer::Base.deliveries.clear
  end

  test "dashboard today uses the owner's account time zone" do
    travel_to Time.utc(2026, 7, 6, 6, 30) do
      account = create_account(name: "Elliott Family", time_zone: "America/New_York")
      owner = create_user(email: "owner-timezone@example.test", role: "owner")
      qualify_self_managed_subscription(account)
      create_account_membership(user: owner, account: account)

      sign_in_as owner
      get root_path

      assert_response :success
      assert_includes response.body, "Monday, Jul 6"
      assert_not_includes response.body, "Sunday, Jul 5"
    end
  end

  test "Pacific account renders prior local day when UTC has advanced" do
    travel_to Time.utc(2026, 7, 6, 6, 30) do
      account = create_account(name: "Pacific Owner", time_zone: "America/Los_Angeles")
      account.contacts.create!(name: "Pacific Owner", email: "pacific-owner@example.test", role: "Owner")
      captain = create_user(email: "captain-pacific-time@example.test")
      vessel = create_vessel(account: account, name: "Blue Meridian")
      sign_in_as captain

      get new_vessel_service_visit_path(vessel)
      assert_response :success
      assert_select "input[name='service_visit[visit_date]'][value='2026-07-05']"

      assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
        post vessel_service_visits_path(vessel), params: {
          service_visit: {
            visit_date: Date.new(2026, 7, 5),
            summary: "Pacific-local report."
          }
        }
      end

      visit = ServiceVisit.find_by!(summary: "Pacific-local report.")
      assert_equal Date.new(2026, 7, 5), visit.visit_date
      assert_equal Time.utc(2026, 7, 6, 6, 30).to_i, visit.created_at.utc.to_i

      mail = ActionMailer::Base.deliveries.last
      assert_includes mail.subject, Date.new(2026, 7, 5).to_fs(:long)
      assert_not_includes mail.subject, Date.new(2026, 7, 6).to_fs(:long)
      assert mail.multipart?
      assert_includes mail.html_part.body.decoded, "Jul 5, 2026 at 11:30 PM PDT"
      assert_not_includes mail.html_part.body.decoded, "Jul 6, 2026 at 6:30 AM UTC"

      get report_vessel_service_visit_path(vessel, visit)
      assert_response :success
      assert_includes response.body, "Jul 5, 2026 at 11:30 PM PDT"
    end
  end

  test "Eastern account renders next local day for the same UTC timestamp" do
    travel_to Time.utc(2026, 7, 6, 6, 30) do
      account = create_account(name: "Eastern Owner", time_zone: "America/New_York")
      account.contacts.create!(name: "Eastern Owner", email: "eastern-owner@example.test", role: "Owner")
      captain = create_user(email: "captain-eastern-time@example.test")
      vessel = create_vessel(account: account, name: "Harbor Light")
      reminder = vessel.reminders.create!(title: "Replace zincs", due_date: Date.new(2026, 7, 5), reminder_type: "maintenance")
      sign_in_as captain

      get new_vessel_service_visit_path(vessel)
      assert_response :success
      assert_select "input[name='service_visit[visit_date]'][value='2026-07-06']"

      assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
        post vessel_service_visits_path(vessel), params: {
          service_visit: {
            visit_date: Date.new(2026, 7, 6),
            summary: "Eastern-local report."
          }
        }
      end

      visit = ServiceVisit.find_by!(summary: "Eastern-local report.")
      assert_equal Date.new(2026, 7, 6), visit.visit_date

      mail = ActionMailer::Base.deliveries.last
      assert_includes mail.subject, Date.new(2026, 7, 6).to_fs(:long)
      assert mail.multipart?
      assert_includes mail.html_part.body.decoded, "Jul 6, 2026 at 2:30 AM EDT"

      get report_vessel_service_visit_path(vessel, visit)
      assert_response :success
      assert_includes response.body, "Jul 6, 2026 at 2:30 AM EDT"

      get reminders_path
      assert_response :success
      assert_includes response.body, "due Jul 5, 2026"
      assert_equal Date.new(2026, 7, 5), reminder.reload.due_date
    end
  end
end
