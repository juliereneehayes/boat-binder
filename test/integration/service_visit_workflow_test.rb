require "test_helper"

class ServiceVisitWorkflowTest < ActionDispatch::IntegrationTest
  setup do
    ActionMailer::Base.deliveries.clear
  end

  teardown do
    ActionMailer::Base.deliveries.clear
  end

  test "captain views all service visits from dashboard and navigation" do
    captain = create_user(email: "captain-visits@example.test")
    sign_in_as captain
    vessel = create_vessel(name: "Blue Meridian")
    other_vessel = create_vessel(account: create_account(name: "Harbor North"), name: "Tide Runner")
    vessel.service_visits.create!(performed_by_user: captain, visit_date: Date.current, summary: "Primary visit")
    other_vessel.service_visits.create!(performed_by_user: captain, visit_date: Date.yesterday, summary: "Second visit")

    get root_path

    assert_response :success
    assert_select "a[href='#{service_visits_path}']", text: "Service Visits"
    assert_select "a[href='#{service_visits_path}']", text: "View all"
    assert_select "nav.fixed a", text: "Vessels"
    assert_select "nav.fixed a", text: "Fleet", count: 0

    get service_visits_path

    assert_response :success
    assert_includes response.body, "Primary visit"
    assert_includes response.body, "Second visit"
    assert_includes response.body, "Blue Meridian"
    assert_includes response.body, "Tide Runner"
    assert_includes response.body, "A reverse-chronological service history"
    assert_operator response.body.index("Primary visit"), :<, response.body.index("Second visit")
  end

  test "service visits index renders empty state" do
    sign_in_as

    get service_visits_path

    assert_response :success
    assert_includes response.body, "No service visits recorded yet."
    assert_includes response.body, "owner-ready reports"
  end

  test "owner all service visits page is scoped to associated vessels" do
    owner_account = create_account(name: "Elliott Family")
    other_account = create_account(name: "Harbor North")
    owner_vessel = create_vessel(account: owner_account, name: "Blue Meridian")
    other_vessel = create_vessel(account: other_account, name: "Tide Runner")
    captain = create_user(email: "captain-scope@example.test")
    owner = create_user(email: "owner-visits@example.test", role: "owner")
    qualify_self_managed_subscription(owner_account)
    create_account_membership(user: owner, account: owner_account)
    owner_vessel.service_visits.create!(performed_by_user: captain, visit_date: Date.current, summary: "Owner visible visit")
    other_vessel.service_visits.create!(performed_by_user: captain, visit_date: Date.current, summary: "Restricted visit")
    sign_in_as owner

    get service_visits_path

    assert_response :success
    assert_includes response.body, "Owner visible visit"
    assert_includes response.body, "Blue Meridian"
    assert_not_includes response.body, "Restricted visit"
    assert_not_includes response.body, "Tide Runner"
  end

  test "owner cannot access out of scope service visit report" do
    owner_account = create_account(name: "Elliott Family")
    other_account = create_account(name: "Harbor North")
    create_vessel(account: owner_account, name: "Blue Meridian")
    other_vessel = create_vessel(account: other_account, name: "Tide Runner")
    captain = create_user(email: "captain-report-scope@example.test")
    owner = create_user(email: "owner-report-scope@example.test", role: "owner")
    create_account_membership(user: owner, account: owner_account)
    restricted_visit = other_vessel.service_visits.create!(
      performed_by_user: captain,
      visit_date: Date.current,
      summary: "Restricted visit report"
    )
    sign_in_as owner

    get vessel_service_visit_path(other_vessel, restricted_visit)

    assert_response :not_found

    get report_vessel_service_visit_path(other_vessel, restricted_visit)

    assert_response :not_found
  end

  test "captain starts a visit with default engines checklist and battery checks" do
    sign_in_as
    vessel = create_vessel
    create_battery(asset: vessel, name: "House Battery 1")

    get new_vessel_service_visit_path(vessel)

    assert_response :success
    assert_includes response.body, "Port Engine Hours"
    assert_includes response.body, "Starboard Engine Hours"
    assert_includes response.body, "Bilge"
    assert_includes response.body, "Shore power"
    assert_includes response.body, "House Battery 1"
    assert_select "label[for='service_visit_photos']", "Choose or take photos"
    assert_select "input[type='file'][name='service_visit[photos][]'][accept=?][multiple]", ServiceVisit::ALLOWED_PHOTO_CONTENT_TYPES.join(",")
    assert_select "input[type='file'][name='service_visit[photos][]'][capture]", count: 0
  end

  test "service visit dates use app timezone for defaults and summary emails" do
    travel_to Time.utc(2026, 7, 6, 6, 30) do
      account = create_account(name: "Elliott Family")
      account.contacts.create!(name: "Elliott Owner", email: "elliott@example.test", role: "Owner")
      captain = create_user(email: "captain-timezone@example.test")
      vessel = create_vessel(account: account, name: "Blue Meridian")
      sign_in_as captain

      get new_vessel_service_visit_path(vessel)

      assert_response :success
      assert_select "input[name='service_visit[visit_date]'][value='2026-07-05']"

      assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
        post vessel_service_visits_path(vessel), params: {
          service_visit: {
            visit_date: Date.current,
            summary: "Pacific timezone dock check."
          }
        }
      end

      mail = ActionMailer::Base.deliveries.last

      assert_includes mail.subject, Date.new(2026, 7, 5).to_fs(:long)
      assert_not_includes mail.subject, Date.new(2026, 7, 6).to_fs(:long)
      assert mail.multipart?
      assert_includes mail.html_part.body.decoded, "Jul 5, 2026"
      assert_not_includes mail.html_part.body.decoded, "Jul 6, 2026"
    end
  end

  test "captain saves structured service visit data and report renders it" do
    sign_in_as
    vessel = create_vessel
    battery = create_battery(asset: vessel, name: "Port Start Battery")
    vessel.ensure_default_engines!
    port_engine = vessel.asset_engines.find_by!(name: "Port")
    starboard_engine = vessel.asset_engines.find_by!(name: "Starboard")

    assert_difference -> { ServiceVisit.count }, 1 do
      post vessel_service_visits_path(vessel), params: {
        service_visit: {
          visit_date: Date.current,
          location: "Bainbridge Marina, Slip C-18",
          summary: "Vessel checked and ready for weekend use.",
          condition_notes: "Decks clean and bilge dry.",
          follow_up_needed: "1",
          follow_up_notes: "Replace chafed spring line.",
          engine_readings: {
            port_engine.id.to_s => { hours: "124.5" },
            starboard_engine.id.to_s => { hours: "125.0" }
          },
          inspection_checks: {
            "0" => { checked: "1", notes: "Hull clean." },
            "1" => { checked: "1", notes: "Bilge dry." },
            "2" => { checked: "0", notes: "Cord strain relief should be watched." }
          },
          battery_checks: {
            battery.id.to_s => { checked: "1", voltage: "12.72", notes: "Charging normally." }
          }
        }
      }
    end

    visit = ServiceVisit.find_by!(summary: "Vessel checked and ready for weekend use.")
    assert_redirected_to vessel_service_visit_path(vessel, visit)
    assert_equal 2, visit.service_visit_engine_readings.count
    assert_equal 9, visit.service_visit_inspection_checks.count
    assert_equal 1, visit.service_visit_battery_checks.count
    assert_equal "Hull clean.", visit.service_visit_inspection_checks.find_by!(label: "Hull").notes
    assert_equal 12.72.to_d, visit.service_visit_battery_checks.first.voltage

    get vessel_service_visit_path(vessel, visit)
    assert_response :success
    assert_includes response.body, "Client-ready service report"
    assert_includes response.body, "Back to service visits"
    assert_includes response.body, "Preview Report"
    assert_includes response.body, "Port Engine"
    assert_includes response.body, "124.5"
    assert_includes response.body, "Inspection checklist"
    assert_includes response.body, "Hull clean."
    assert_includes response.body, "Port Start Battery"
    assert_includes response.body, "12.72 V"
    assert_includes response.body, "Replace chafed spring line."
    assert_includes response.body, "Follow-up items"

    get report_vessel_service_visit_path(vessel, visit)
    assert_response :success
    assert_includes response.body, "Client-ready service report"
    assert_includes response.body, "Back to visit details"
    assert_includes response.body, "Replace chafed spring line."

    mail = ServiceVisitMailer.summary(visit, "owner@example.test")

    assert mail.multipart?
    assert_includes mail.html_part.body.decoded, "Visit summary"
    assert_includes mail.html_part.body.decoded, "2 of 9 complete"
    assert_includes mail.html_part.body.decoded, "2 engines recorded"
    assert_includes mail.html_part.body.decoded, "Engine summary"
    assert_not_includes mail.html_part.body.decoded, "Engine hours"
    assert_not_includes mail.html_part.body.decoded, "Port Engine"
    assert_not_includes mail.html_part.body.decoded, "Starboard Engine"
    assert_not_includes mail.html_part.body.decoded, "Hull clean."
    assert_not_includes mail.html_part.body.decoded, "Port Start Battery"
    assert_not_includes mail.html_part.body.decoded, "12.72 V"
  end

  test "captain saves service visit with valid image photos" do
    sign_in_as
    vessel = create_vessel

    assert_difference -> { ServiceVisit.count }, 1 do
      post vessel_service_visits_path(vessel), params: {
        service_visit: {
          visit_date: Date.current,
          summary: "Photo log from dock walk.",
          photos: [
            fixture_file_upload("sample.jpg", "image/jpeg"),
            fixture_file_upload("sample.webp", "image/webp")
          ]
        }
      }
    end

    visit = ServiceVisit.find_by!(summary: "Photo log from dock walk.")
    assert_redirected_to vessel_service_visit_path(vessel, visit)
    assert_equal 2, visit.photos.count
    assert_equal [ "image/jpeg", "image/webp" ], visit.photos.map { |photo| photo.blob.content_type }
  end

  test "service visit photos reject non image uploads" do
    sign_in_as
    vessel = create_vessel

    assert_no_difference -> { ServiceVisit.count } do
      assert_no_difference -> { ActiveStorage::Blob.count } do
        assert_no_difference -> { ActiveStorage::Attachment.count } do
          post vessel_service_visits_path(vessel), params: {
            service_visit: {
              visit_date: Date.current,
              summary: "PDF should not attach as a photo.",
              photos: [
                fixture_file_upload("sample.pdf", "application/pdf")
              ]
            }
          }
        end
      end
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "Photos must be JPEG, PNG, or WEBP images"
  end

  test "service visit creation emails owner user summary report" do
    account = create_account(name: "Elliott Family")
    account.contacts.create!(name: "Fallback Owner", email: "fallback-owner@example.test", role: "Owner")
    owner = create_user(email: "owner-summary@example.test", role: "owner")
    captain = create_user(email: "captain-summary@example.test")
    create_account_membership(user: owner, account: account)
    vessel = create_vessel(account: account, name: "Blue Meridian")
    sign_in_as captain

    assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
      post vessel_service_visits_path(vessel), params: {
        service_visit: {
          visit_date: Date.current,
          location: "Bainbridge Marina",
          summary: "Systems checked and ready.",
          condition_notes: "Bilge dry and shore power stable.",
          follow_up_needed: "1",
          follow_up_notes: [
            "Replace chafed spring line.",
            "Schedule diver for running gear inspection.",
            "Order spare fuel filters.",
            "Review shore power cord."
          ].join("\n")
        }
      }
    end

    visit = ServiceVisit.find_by!(summary: "Systems checked and ready.")
    mail = ActionMailer::Base.deliveries.last
    mailer_url_options = Rails.application.config.action_mailer.default_url_options
    expected_report_url = report_vessel_service_visit_url(vessel, visit, **mailer_url_options)

    assert_redirected_to vessel_service_visit_path(vessel, visit)
    assert_equal [ "owner-summary@example.test" ], mail.to
    assert_includes mail.subject, "Blue Meridian"
    assert_includes mail.subject, visit.visit_date.to_fs(:long)
    assert mail.multipart?
    assert_includes mail.html_part.body.decoded, "Boat Binder"
    assert_includes mail.html_part.body.decoded, "Blue Meridian Service Visit"
    assert_includes mail.html_part.body.decoded, "Visit summary"
    assert_includes mail.html_part.body.decoded, "Follow-up status"
    assert_includes mail.html_part.body.decoded, "Follow-up needed"
    assert_includes mail.html_part.body.decoded, "Inspection"
    assert_includes mail.html_part.body.decoded, "Engine summary"
    assert_not_includes mail.html_part.body.decoded, "Engine hours"
    assert_includes mail.html_part.body.decoded, "Battery checks"
    assert_includes mail.html_part.body.decoded, "0 photos"
    assert_includes mail.html_part.body.decoded, "Notes preview"
    assert_includes mail.html_part.body.decoded, "Systems checked and ready."
    assert_includes mail.html_part.body.decoded, "Replace chafed spring line."
    assert_includes mail.html_part.body.decoded, "Schedule diver for running gear inspection."
    assert_includes mail.html_part.body.decoded, "Order spare fuel filters."
    assert_not_includes mail.html_part.body.decoded, "Review shore power cord."
    assert_not_includes mail.html_part.body.decoded, "No follow-up items noted."
    assert_includes mail.html_part.body.decoded, "View full report in Boat Binder"
    assert_includes mail.html_part.body.decoded, expected_report_url
    assert_not_includes mail.html_part.body.decoded, "Client-ready service report"
    assert_not_includes mail.html_part.body.decoded, "Inspection checklist"
    assert_not_includes mail.html_part.body.decoded, "Engine readings"
    assert_includes mail.text_part.body.decoded, "Systems checked and ready."
    assert_includes mail.text_part.body.decoded, "VISIT SUMMARY"
    assert_includes mail.text_part.body.decoded, "Follow-up status: Follow-up needed"
    assert_includes mail.text_part.body.decoded, "Engine summary"
    assert_not_includes mail.text_part.body.decoded, "Engine hours"
    assert_includes mail.text_part.body.decoded, "FOLLOW-UP ITEMS"
    assert_includes mail.text_part.body.decoded, "- Replace chafed spring line."
    assert_not_includes mail.text_part.body.decoded, "- Review shore power cord."
    assert_not_includes mail.text_part.body.decoded, "No follow-up items noted."
    assert_includes mail.text_part.body.decoded, expected_report_url
  end

  test "service visit creation passes computed summary recipient to mailer once" do
    account = create_account(name: "Elliott Family")
    owner = create_user(email: "single-lookup-owner@example.test", role: "owner")
    captain = create_user(email: "single-lookup-captain@example.test")
    create_account_membership(user: owner, account: account)
    vessel = create_vessel(account: account, name: "Sea Glass")
    original_summary_recipient_email = ServiceVisit.instance_method(:summary_recipient_email)
    lookup_count = 0
    ServiceVisit.define_method(:summary_recipient_email) do
      lookup_count += 1
      original_summary_recipient_email.bind(self).call
    end
    sign_in_as captain

    assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
      post vessel_service_visits_path(vessel), params: {
        service_visit: {
          visit_date: Date.current,
          summary: "Single recipient lookup."
        }
      }
    end

    assert_redirected_to vessel_service_visit_path(vessel, ServiceVisit.last)
    assert_equal 1, lookup_count
    assert_equal [ "single-lookup-owner@example.test" ], ActionMailer::Base.deliveries.last.to
  ensure
    ServiceVisit.define_method(:summary_recipient_email, original_summary_recipient_email) if original_summary_recipient_email
  end

  test "service visit summary recipient uses first active owner by membership order" do
    account = create_account(name: "Harbor North")
    captain_member = create_user(email: "captain-member-summary@example.test", role: "captain")
    inactive_owner = create_user(email: "inactive-owner-summary@example.test", role: "owner", active: false)
    first_active_owner = create_user(email: "first-owner-summary@example.test", role: "owner")
    second_active_owner = create_user(email: "second-owner-summary@example.test", role: "owner")
    captain = create_user(email: "captain-owner-order@example.test")
    create_account_membership(user: captain_member, account: account)
    create_account_membership(user: inactive_owner, account: account)
    first_membership = create_account_membership(user: first_active_owner, account: account)
    second_membership = create_account_membership(user: second_active_owner, account: account)
    vessel = create_vessel(account: account, name: "Tide Runner")
    visit = vessel.service_visits.create!(
      performed_by_user: captain,
      visit_date: Date.current,
      summary: "Owner order summary."
    )

    mail = ServiceVisitMailer.summary(visit, visit.summary_recipient_email)

    assert_operator first_membership.id, :<, second_membership.id
    assert_equal [ "first-owner-summary@example.test" ], mail.to
  end

  test "service visit summary email falls back to account primary contact and shows no follow-up state" do
    account = create_account(name: "Marisol Trust")
    account.contacts.create!(name: "Marisol Owner", email: "marisol@example.test", role: "Owner")
    vessel = create_vessel(account: account, name: "Solstice")
    visit = vessel.service_visits.create!(
      performed_by_user: create_user(email: "captain-contact-summary@example.test"),
      visit_date: Date.current,
      summary: "Routine dock check complete.",
      follow_up_needed: false
    )

    mail = ServiceVisitMailer.summary(visit, visit.summary_recipient_email)

    assert_equal [ "marisol@example.test" ], mail.to
    assert_includes mail.subject, "Solstice"
    assert mail.multipart?
    assert_includes mail.html_part.body.decoded, "No follow-up needed"
    assert_includes mail.html_part.body.decoded, "No follow-up items noted."
    assert_includes mail.text_part.body.decoded, "Follow-up status: No follow-up needed"
    assert_includes mail.text_part.body.decoded, "No follow-up items noted."
    assert_not_includes mail.html_part.body.decoded, "Follow-up was marked during this visit."
    assert_not_includes mail.text_part.body.decoded, "Follow-up was marked during this visit."
    assert_not_includes mail.html_part.body.decoded, "Action needed"
    assert_not_includes mail.html_part.body.decoded, "Follow-up needed"
  end

  test "service visit summary email renders follow-up items even when follow_up_needed is false" do
    account = create_account(name: "Marisol Trust")
    account.contacts.create!(name: "Marisol Owner", email: "marisol-notes@example.test", role: "Owner")
    vessel = create_vessel(account: account, name: "Sea Glass")
    visit = vessel.service_visits.create!(
      performed_by_user: create_user(email: "captain-follow-up-notes@example.test"),
      visit_date: Date.current,
      summary: "Routine dock check complete.",
      follow_up_needed: false,
      follow_up_notes: "Monitor shore power cord.\nCheck dock line chafe."
    )

    mail = ServiceVisitMailer.summary(visit, visit.summary_recipient_email)

    assert mail.multipart?
    assert_includes mail.html_part.body.decoded, "No follow-up needed"
    assert_includes mail.html_part.body.decoded, "Monitor shore power cord."
    assert_includes mail.html_part.body.decoded, "Check dock line chafe."
    assert_not_includes mail.html_part.body.decoded, "No follow-up items noted."
    assert_not_includes mail.html_part.body.decoded, "Follow-up was marked during this visit."
    assert_includes mail.text_part.body.decoded, "Follow-up status: No follow-up needed"
    assert_includes mail.text_part.body.decoded, "- Monitor shore power cord."
    assert_includes mail.text_part.body.decoded, "- Check dock line chafe."
    assert_not_includes mail.text_part.body.decoded, "No follow-up items noted."
    assert_not_includes mail.text_part.body.decoded, "Follow-up was marked during this visit."
  end

  test "service visit report does not show action label when follow up notes are blank" do
    account = create_account(name: "Harbor North")
    account.contacts.create!(name: "Harbor Owner", email: "harbor@example.test", role: "Owner")
    captain = create_user(email: "captain-empty-follow-up@example.test")
    vessel = create_vessel(account: account, name: "Tide Runner")
    visit = vessel.service_visits.create!(
      performed_by_user: captain,
      visit_date: Date.current,
      summary: "Routine check complete.",
      follow_up_needed: true,
      follow_up_notes: ""
    )
    sign_in_as captain

    get report_vessel_service_visit_path(vessel, visit)

    assert_response :success
    assert_includes response.body, "No follow-up items noted."
    assert_not_includes response.body, "Action needed"
    assert_not_includes response.body, "Follow-up needed"

    mail = ServiceVisitMailer.summary(visit, visit.summary_recipient_email)

    assert mail.multipart?
    assert_includes mail.html_part.body.decoded, "Follow-up needed"
    assert_includes mail.html_part.body.decoded, "Follow-up was marked during this visit."
    assert_includes mail.text_part.body.decoded, "Follow-up status: Follow-up needed"
    assert_includes mail.text_part.body.decoded, "Follow-up was marked during this visit."
    assert_not_includes mail.html_part.body.decoded, "No follow-up items noted."
    assert_not_includes mail.text_part.body.decoded, "No follow-up items noted."
    assert_not_includes mail.html_part.body.decoded, "Action needed"
  end

  test "service visit summary email is skipped when no recipient exists" do
    captain = create_user(email: "captain-no-recipient@example.test")
    sign_in_as captain
    vessel = create_vessel(name: "No Recipient")

    assert_no_difference -> { ActionMailer::Base.deliveries.size } do
      post vessel_service_visits_path(vessel), params: {
        service_visit: {
          visit_date: Date.current,
          summary: "No recipient report"
        }
      }
    end

    assert_redirected_to vessel_service_visit_path(vessel, ServiceVisit.last)
  end

  test "service visit summary delivery failure does not prevent creation" do
    account = create_account(name: "Harbor North")
    account.contacts.create!(name: "Harbor Owner", email: "harbor@example.test", role: "Owner")
    captain = create_user(email: "captain-delivery-failure@example.test")
    vessel = create_vessel(account: account, name: "Tide Runner")
    failed_delivery = Object.new
    failed_delivery.define_singleton_method(:deliver_now) do
      raise Errno::ECONNREFUSED, "connect(2) for localhost port 25"
    end
    original_summary = ServiceVisitMailer.method(:summary)
    ServiceVisitMailer.define_singleton_method(:summary) { |_visit, _recipient_email| failed_delivery }
    sign_in_as captain

    assert_difference -> { ServiceVisit.count }, 1 do
      assert_no_difference -> { ActionMailer::Base.deliveries.size } do
        post vessel_service_visits_path(vessel), params: {
          service_visit: {
            visit_date: Date.current,
            summary: "Delivery failure should not break create"
          }
        }
      end
    end

    assert_redirected_to vessel_service_visit_path(vessel, ServiceVisit.last)
  ensure
    ServiceVisitMailer.define_singleton_method(:summary, original_summary) if original_summary
  end

  test "vessel page shows service history timeline" do
    captain = create_user(email: "captain-history@example.test")
    sign_in_as captain
    vessel = create_vessel(name: "Blue Meridian")
    vessel.service_visits.create!(
      performed_by_user: captain,
      visit_date: Date.current,
      summary: "Quarterly systems check",
      follow_up_needed: true,
      follow_up_notes: "Order spare impeller."
    )

    get vessel_path(vessel)

    assert_response :success
    assert_includes response.body, "Vessel history"
    assert_includes response.body, "Quarterly systems check"
    assert_includes response.body, "View all service visits"
    assert_includes response.body, "View visit details"
    assert_includes response.body, "Follow-up"
  end

  test "older service visit report without structured records renders" do
    sign_in_as
    vessel = create_vessel
    visit = vessel.service_visits.create!(
      performed_by_user: create_user(email: "legacy@example.test"),
      visit_date: Date.current,
      engine_hours: 88.4,
      summary: "Legacy report",
      condition_notes: "Legacy condition notes."
    )

    get vessel_service_visit_path(vessel, visit)

    assert_response :success
    assert_includes response.body, "88.4"
    assert_includes response.body, "Legacy condition notes."
    assert_includes response.body, "No battery checks were recorded"
  end

  test "captain creates and edits vessel batteries" do
    sign_in_as
    vessel = create_vessel

    assert_difference -> { AssetBattery.count }, 1 do
      post vessel_batteries_path(vessel), params: {
        asset_battery: {
          name: "House Battery 1",
          location: "Engine room",
          battery_type: "AGM",
          notes: "Installed spring 2025",
          active: "1"
        }
      }
    end

    battery = AssetBattery.find_by!(name: "House Battery 1")
    assert_redirected_to vessel_path(vessel, anchor: "batteries")

    patch vessel_battery_path(vessel, battery), params: {
      asset_battery: {
        name: "House Battery Bank",
        location: "Aft lazarette",
        battery_type: "Lithium",
        notes: "Monitor charging profile.",
        active: "0"
      }
    }

    assert_redirected_to vessel_path(vessel, anchor: "batteries")
    battery.reload
    assert_equal "House Battery Bank", battery.name
    assert_equal "Aft lazarette", battery.location
    assert_not battery.active?
  end
end
