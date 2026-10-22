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
      owner = verified_owner(email: "elliott-verified-owner@example.test")
      create_account_membership(user: owner, account:)
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
    owner = verified_owner(email: "structured-visit-owner@example.test")
    create_account_membership(user: owner, account: vessel.account)
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
    assert_equal 124.5.to_d, visit.service_visit_engine_readings.find_by!(asset_engine: port_engine).hours
    assert_equal 125.0.to_d, visit.service_visit_engine_readings.find_by!(asset_engine: starboard_engine).hours
    hull_check = visit.service_visit_inspection_checks.find_by!(label: "Hull")
    shore_power_check = visit.service_visit_inspection_checks.find_by!(label: "Shore power")
    assert hull_check.checked?
    assert_equal "Hull clean.", hull_check.notes
    assert_not shore_power_check.checked?
    battery_check = visit.service_visit_battery_checks.first
    assert battery_check.checked?
    assert_equal 12.72.to_d, battery_check.voltage
    assert_equal "Charging normally.", battery_check.notes

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

    mail = ServiceVisitMailer.summary(visit, visit.summary_recipient_email)

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

  test "captain updates existing structured visit data and preserves photos" do
    captain = create_user(email: "structured-update-captain@example.test")
    sign_in_as captain
    vessel = create_vessel
    battery = create_battery(asset: vessel, name: "House Battery")
    vessel.ensure_default_engines!
    port_engine = vessel.asset_engines.find_by!(name: "Port")
    visit = vessel.service_visits.new(
      performed_by_user: captain,
      visit_date: Date.current,
      location: "Original marina"
    )
    visit.build_workflow_defaults
    visit.save!
    visit.photos.attach(fixture_file_upload("sample.jpg", "image/jpeg"))
    original_blob_ids = visit.photos.blobs.ids
    hull_check = visit.service_visit_inspection_checks.find_by!(label: "Hull")
    bilge_check = visit.service_visit_inspection_checks.find_by!(label: "Bilge")
    hull_check.update!(checked: true, notes: "Original hull note")
    bilge_check.update!(checked: false)
    visit.service_visit_engine_readings.find_by!(asset_engine: port_engine).update!(hours: 100.0)
    visit.service_visit_battery_checks.find_by!(asset_battery: battery).update!(
      checked: false,
      voltage: 12.4,
      notes: "Original battery note"
    )

    inspection_params = visit.ordered_inspection_checks.each_with_index.to_h do |check, index|
      values = case check.label
      when "Hull"
        { checked: "0", notes: "Updated hull note" }
      when "Bilge"
        { checked: "1", notes: "Updated bilge note" }
      else
        { checked: check.checked? ? "1" : "0", notes: check.notes }
      end
      [ index.to_s, values ]
    end

    patch vessel_service_visit_path(vessel, visit), params: {
      service_visit: {
        visit_date: visit.visit_date,
        location: "Updated marina",
        engine_readings: {
          port_engine.id.to_s => { hours: "321.5" }
        },
        inspection_checks: inspection_params,
        battery_checks: {
          battery.id.to_s => {
            checked: "1",
            voltage: "13.10",
            notes: "Updated battery note"
          }
        }
      }
    }

    assert_redirected_to vessel_service_visit_path(vessel, visit)
    visit.reload
    assert_equal "Updated marina", visit.location
    assert_not visit.service_visit_inspection_checks.find_by!(label: "Hull").checked?
    assert_equal "Updated hull note", visit.service_visit_inspection_checks.find_by!(label: "Hull").notes
    assert visit.service_visit_inspection_checks.find_by!(label: "Bilge").checked?
    assert_equal "Updated bilge note", visit.service_visit_inspection_checks.find_by!(label: "Bilge").notes
    assert_equal 321.5.to_d, visit.service_visit_engine_readings.find_by!(asset_engine: port_engine).hours
    battery_check = visit.service_visit_battery_checks.find_by!(asset_battery: battery)
    assert battery_check.checked?
    assert_equal 13.1.to_d, battery_check.voltage
    assert_equal "Updated battery note", battery_check.notes
    assert_equal original_blob_ids, visit.photos.blobs.ids
  end

  test "invalid structured visit update rolls back parent children and new photos" do
    captain = create_user(email: "structured-rollback-captain@example.test")
    sign_in_as captain
    vessel = create_vessel
    battery = create_battery(asset: vessel, name: "House Battery")
    visit = vessel.service_visits.new(
      performed_by_user: captain,
      visit_date: Date.current,
      location: "Original marina"
    )
    visit.build_workflow_defaults
    visit.save!
    visit.photos.attach(fixture_file_upload("sample.jpg", "image/jpeg"))
    original_blob_ids = visit.photos.blobs.ids
    hull_check = visit.service_visit_inspection_checks.find_by!(label: "Hull")
    engine_reading = visit.service_visit_engine_readings.first
    battery_check = visit.service_visit_battery_checks.find_by!(asset_battery: battery)

    assert_no_difference -> { ActiveStorage::Blob.count } do
      assert_no_difference -> { ActiveStorage::Attachment.count } do
        patch vessel_service_visit_path(vessel, visit), params: {
          service_visit: {
            visit_date: visit.visit_date,
            location: "Must roll back",
            photos: [ fixture_file_upload("sample.png", "image/png") ],
            engine_readings: {
              engine_reading.asset_engine_id.to_s => { hours: "777.7" }
            },
            inspection_checks: {
              "0" => { checked: "1", notes: "x" * 2_001 }
            },
            battery_checks: {
              battery.id.to_s => { checked: "1", voltage: "13.25", notes: "Must roll back" }
            }
          }
        }
      end
    end

    assert_response :unprocessable_entity
    visit.reload
    assert_equal "Original marina", visit.location
    assert_not hull_check.reload.checked?
    assert_nil hull_check.notes
    assert_nil engine_reading.reload.hours
    assert_not battery_check.reload.checked?
    assert_nil battery_check.voltage
    assert_nil battery_check.notes
    assert_equal original_blob_ids, visit.photos.blobs.ids
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

  test "service visit photos reject more than ten files before attaching any" do
    sign_in_as
    vessel = create_vessel
    uploads = Array.new(11) { fixture_file_upload("sample.jpg", "image/jpeg") }

    assert_no_difference -> { ServiceVisit.count } do
      assert_no_difference -> { ActiveStorage::Blob.count } do
        assert_no_difference -> { ActiveStorage::Attachment.count } do
          post vessel_service_visits_path(vessel), params: {
            service_visit: { visit_date: Date.current, photos: uploads }
          }
        end
      end
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "Photos upload no more than 10 photos at a time"
  end

  test "service visit photos accept the inclusive count individual and aggregate limits" do
    sign_in_as
    vessel = create_vessel
    boundary_sizes = [
      10.megabytes,
      8.megabytes,
      *Array.new(8, 4.megabytes)
    ]

    assert_equal 10, ServiceVisit::PHOTO_MAX_FILES_PER_SUBMISSION
    assert_equal 10.megabytes, ServiceVisit::PHOTO_MAX_SIZE
    assert_equal 50.megabytes, ServiceVisit::PHOTO_MAX_AGGREGATE_SIZE

    with_sized_photo_uploads(boundary_sizes) do |uploads|
      assert_difference -> { ServiceVisit.count }, 1 do
        assert_difference -> { ActiveStorage::Blob.count }, 10 do
          assert_difference -> { ActiveStorage::Attachment.count }, 10 do
            post vessel_service_visits_path(vessel), params: {
              service_visit: {
                visit_date: Date.current,
                summary: "Photos at inclusive upload limits.",
                photos: uploads
              }
            }
          end
        end
      end
    end

    visit = ServiceVisit.find_by!(summary: "Photos at inclusive upload limits.")
    byte_sizes = visit.photos.blobs.pluck(:byte_size)

    assert_redirected_to vessel_service_visit_path(vessel, visit)
    assert_equal 10, byte_sizes.size
    assert_equal 10.megabytes, byte_sizes.max
    assert_equal 50.megabytes, byte_sizes.sum
  end

  test "one oversized service visit photo rejects all new photos and preserves existing photos" do
    captain = create_user(email: "oversized-photo-captain@example.test")
    sign_in_as captain
    vessel = create_vessel
    visit = vessel.service_visits.create!(performed_by_user: captain, visit_date: Date.current)
    visit.photos.attach(fixture_file_upload("sample.jpg", "image/jpeg"))
    original_blob_ids = visit.photos.blobs.ids

    with_sized_photo_uploads([ ServiceVisit::PHOTO_MAX_SIZE + 1 ]) do |oversized_uploads|
      uploads = [ fixture_file_upload("sample.png", "image/png"), *oversized_uploads ]

      assert_no_difference -> { ActiveStorage::Blob.count } do
        assert_no_difference -> { ActiveStorage::Attachment.count } do
          patch vessel_service_visit_path(vessel, visit), params: {
            service_visit: { visit_date: visit.visit_date, photos: uploads }
          }
        end
      end
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "Photos must be 10 MB or smaller"
    assert_equal original_blob_ids, visit.reload.photos.blobs.ids
  end

  test "service visit photos reject an aggregate upload over fifty megabytes" do
    sign_in_as
    vessel = create_vessel

    with_sized_photo_uploads(Array.new(6, 9.megabytes)) do |uploads|
      assert_no_difference -> { ServiceVisit.count } do
        assert_no_difference -> { ActiveStorage::Blob.count } do
          assert_no_difference -> { ActiveStorage::Attachment.count } do
            post vessel_service_visits_path(vessel), params: {
              service_visit: { visit_date: Date.current, photos: uploads }
            }
          end
        end
      end
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "Photos must total 50 MB or less"
  end

  test "service visit photo extension mismatch rejects the complete new set" do
    captain = create_user(email: "extension-photo-captain@example.test")
    sign_in_as captain
    vessel = create_vessel
    visit = vessel.service_visits.create!(performed_by_user: captain, visit_date: Date.current)
    visit.photos.attach(fixture_file_upload("sample.webp", "image/webp"))
    original_blob_ids = visit.photos.blobs.ids
    mismatched_upload = Rack::Test::UploadedFile.new(
      file_fixture("sample.png"),
      "image/png",
      true,
      original_filename: "misleading.jpg"
    )

    assert_no_difference -> { ActiveStorage::Blob.count } do
      assert_no_difference -> { ActiveStorage::Attachment.count } do
        patch vessel_service_visit_path(vessel, visit), params: {
          service_visit: {
            visit_date: visit.visit_date,
            photos: [ fixture_file_upload("sample.jpg", "image/jpeg"), mismatched_upload ]
          }
        }
      end
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "Photos extension does not match the uploaded file type"
    assert_equal original_blob_ids, visit.reload.photos.blobs.ids
  end

  test "service visit creation emails owner user summary report" do
    account = create_account(name: "Elliott Family")
    account.contacts.create!(name: "Fallback Owner", email: "fallback-owner@example.test", role: "Owner")
    owner = verified_owner(email: "owner-summary@example.test")
    captain = create_user(email: "captain-summary@example.test")
    create_account_membership(user: owner, account: account)
    vessel = create_vessel(account: account, name: "Blue Meridian")
    sign_in_as captain

    assert_difference -> { SecurityAuditEvent.where(action: "service_visit.summary_delivery").count }, 1 do
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
    end

    visit = ServiceVisit.find_by!(summary: "Systems checked and ready.")
    mail = ActionMailer::Base.deliveries.last
    mailer_url_options = Rails.application.config.action_mailer.default_url_options
    expected_report_url = report_vessel_service_visit_url(vessel, visit, **mailer_url_options)

    assert_redirected_to vessel_service_visit_path(vessel, visit)
    assert_equal [ "owner-summary@example.test" ], mail.to
    audit_event = SecurityAuditEvent.where(action: "service_visit.summary_delivery").order(:id).last
    assert_equal "succeeded", audit_event.outcome
    assert_equal captain, audit_event.actor_user
    assert_equal account, audit_event.account
    assert_equal "ServiceVisit", audit_event.target_type
    assert_equal visit.id, audit_event.target_id
    assert audit_event.request_id.present?
    assert_nil audit_event.source_ip
    assert_empty audit_event.changed_fields
    assert_not_includes audit_event.attributes.to_json, owner.email_address
    assert_not_includes audit_event.attributes.to_json, visit.summary
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

  test "admin-created service visit emails eligible owner and records successful delivery" do
    account = create_account(name: "Admin Managed Account")
    owner = verified_owner(email: "admin-visit-owner@example.test")
    create_account_membership(user: owner, account:)
    vessel = create_vessel(account:, name: "Sea Glass")
    admin = create_user(email: "admin-visit@example.test", role: "admin")
    sign_in_as admin

    assert_difference -> { SecurityAuditEvent.where(action: "service_visit.summary_delivery").count }, 1 do
      assert_difference -> { ServiceVisit.count }, 1 do
        assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
          post vessel_service_visits_path(vessel), params: {
            service_visit: {
              visit_date: Date.current,
              summary: "Admin completed the service visit."
            }
          }
        end
      end
    end

    visit = ServiceVisit.find_by!(summary: "Admin completed the service visit.")
    event = SecurityAuditEvent.where(action: "service_visit.summary_delivery").order(:id).last

    assert_redirected_to vessel_service_visit_path(vessel, visit)
    assert_equal admin, visit.performed_by_user
    assert_equal [ owner.email_address ], ActionMailer::Base.deliveries.last.to
    assert_equal "succeeded", event.outcome
    assert_equal admin, event.actor_user
    assert_equal account, event.account
    assert_equal visit.id, event.target_id
  end

  test "owner-created service visit saves without automatic summary delivery or audit event" do
    account = create_account(name: "Self Managed Account")
    qualify_self_managed_subscription(account)
    owner = verified_owner(email: "owner-authored-visit@example.test")
    create_account_membership(user: owner, account:, access_level: "editor")
    vessel = create_vessel(account:, name: "Tide Runner")
    sign_in_as owner

    assert_no_difference -> { SecurityAuditEvent.where(action: "service_visit.summary_delivery").count } do
      assert_no_enqueued_jobs do
        assert_no_difference -> { ActionMailer::Base.deliveries.size } do
          assert_difference -> { ServiceVisit.count }, 1 do
            post vessel_service_visits_path(vessel), params: {
              service_visit: {
                visit_date: Date.current,
                summary: "Owner completed the dock check."
              }
            }
          end
        end
      end
    end

    visit = ServiceVisit.find_by!(summary: "Owner completed the dock check.")

    assert_redirected_to vessel_service_visit_path(vessel, visit)
    assert_equal owner, visit.performed_by_user
  end

  test "service visit creation passes computed summary recipient to mailer once" do
    account = create_account(name: "Elliott Family")
    owner = verified_owner(email: "single-lookup-owner@example.test")
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
    inactive_owner = verified_owner(email: "inactive-owner-summary@example.test")
    inactive_owner.update!(active: false)
    first_active_owner = verified_owner(email: "first-owner-summary@example.test")
    second_active_owner = verified_owner(email: "second-owner-summary@example.test")
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

  test "service visit summary email to a verified owner shows no follow-up state" do
    account = create_account(name: "Marisol Trust")
    account.contacts.create!(name: "Marisol Owner", email: "marisol@example.test", role: "Owner")
    owner = verified_owner(email: "marisol-verified@example.test")
    create_account_membership(user: owner, account:)
    vessel = create_vessel(account: account, name: "Solstice")
    visit = vessel.service_visits.create!(
      performed_by_user: create_user(email: "captain-contact-summary@example.test"),
      visit_date: Date.current,
      summary: "Routine dock check complete.",
      follow_up_needed: false
    )

    mail = ServiceVisitMailer.summary(visit, visit.summary_recipient_email)

    assert_equal [ "marisol-verified@example.test" ], mail.to
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
    owner = verified_owner(email: "marisol-notes-verified@example.test")
    create_account_membership(user: owner, account:)
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

  test "service visit report shows open follow up state when notes are blank" do
    account = create_account(name: "Harbor North")
    account.contacts.create!(name: "Harbor Owner", email: "harbor@example.test", role: "Owner")
    owner = verified_owner(email: "harbor-verified@example.test")
    create_account_membership(user: owner, account:)
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
    assert_includes response.body, "Action needed"
    assert_includes response.body, "Follow-up needed"

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

  test "service visit creation skips manual unverified inactive and cross-account recipients" do
    account = create_account(name: "No Eligible Recipient")
    account.contacts.create!(name: "Manual Owner", email: "manual-owner@example.test", role: "Owner")
    unverified_owner = create_user(email: "unverified-owner@example.test", role: "owner")
    inactive_owner = verified_owner(email: "inactive-owner@example.test")
    inactive_owner.update!(active: false)
    inactive_membership_owner = verified_owner(email: "inactive-membership-owner@example.test")
    other_account = create_account(name: "Other Account")
    other_owner = verified_owner(email: "other-account-owner@example.test")
    create_account_membership(user: unverified_owner, account:)
    create_account_membership(user: inactive_owner, account:)
    create_account_membership(user: inactive_membership_owner, account:, active: false)
    create_account_membership(user: other_owner, account: other_account)
    captain = create_user(email: "captain-no-recipient@example.test")
    sign_in_as captain
    vessel = create_vessel(account:, name: "No Recipient")

    assert_difference -> { SecurityAuditEvent.where(action: "service_visit.summary_delivery").count }, 1 do
      assert_difference -> { ServiceVisit.count }, 1 do
        assert_no_difference -> { ActionMailer::Base.deliveries.size } do
          post vessel_service_visits_path(vessel), params: {
            service_visit: {
              visit_date: Date.current,
              summary: "No recipient report"
            }
          }
        end
      end
    end

    visit = ServiceVisit.order(:id).last
    assert_redirected_to vessel_service_visit_path(vessel, visit)
    event = SecurityAuditEvent.where(action: "service_visit.summary_delivery").order(:id).last
    assert_equal "denied", event.outcome
    assert_equal account, event.account
    assert_equal visit.id, event.target_id
    assert_nil event.source_ip
    serialized_event = event.attributes.to_json
    assert_not_includes serialized_event, "manual-owner@example.test"
    assert_not_includes serialized_event, "No recipient report"
  end

  test "service visit summary delivery failure does not prevent creation" do
    account = create_account(name: "Harbor North")
    account.contacts.create!(name: "Harbor Owner", email: "harbor@example.test", role: "Owner")
    owner = verified_owner(email: "harbor-delivery-owner@example.test")
    create_account_membership(user: owner, account:)
    captain = create_user(email: "captain-delivery-failure@example.test")
    vessel = create_vessel(account: account, name: "Tide Runner")
    failed_delivery = Object.new
    failed_delivery.define_singleton_method(:deliver_now) do
      raise Errno::ECONNREFUSED, "connect(2) for localhost port 25"
    end
    original_summary = ServiceVisitMailer.method(:summary)
    ServiceVisitMailer.define_singleton_method(:summary) { |_visit, _recipient_email| failed_delivery }
    sign_in_as captain

    assert_difference -> { SecurityAuditEvent.where(action: "service_visit.summary_delivery").count }, 1 do
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
    end

    visit = ServiceVisit.order(:id).last
    assert_redirected_to vessel_service_visit_path(vessel, visit)
    event = SecurityAuditEvent.where(action: "service_visit.summary_delivery").order(:id).last
    assert_equal "failed", event.outcome
    assert_equal visit.id, event.target_id
    assert_nil event.source_ip
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

  test "captain completes and reopens follow up without notifications or issue notes" do
    captain = create_user(email: "captain-follow-up-action@example.test", name: "Jordan Captain")
    sign_in_as captain
    vessel = create_vessel(name: "Blue Meridian")
    visit = vessel.service_visits.create!(
      performed_by_user: captain,
      visit_date: Date.current,
      follow_up_needed: true,
      follow_up_notes: "Replace the chafed spring line."
    )

    get vessel_path(vessel)
    assert_response :success
    assert_select "form[action=?]", complete_follow_up_vessel_service_visit_path(vessel, visit)

    assert_no_difference -> { ActionMailer::Base.deliveries.size } do
      assert_no_difference -> { vessel.binder_notes.count } do
        assert_difference -> { ServiceVisitFollowUpEvent.count }, 1 do
          patch complete_follow_up_vessel_service_visit_path(vessel, visit)
        end
      end
    end

    assert_redirected_to vessel_service_visit_path(vessel, visit)
    visit.reload
    assert visit.follow_up_completed?
    assert_equal captain, visit.follow_up_completed_by_user
    assert_equal "Replace the chafed spring line.", visit.follow_up_notes

    follow_redirect!
    assert_includes response.body, "Follow-up completed"
    assert_includes response.body, "Jordan Captain"
    assert_includes response.body, "Follow-up history"
    assert_includes response.body, "Replace the chafed spring line."
    assert_not_includes response.body, "Action needed"

    get vessel_path(vessel)
    assert_response :success
    assert_select "form[action=?]", complete_follow_up_vessel_service_visit_path(vessel, visit), count: 0
    assert_includes response.body, "Follow-up completed"

    assert_no_difference -> { ServiceVisitFollowUpEvent.count } do
      patch complete_follow_up_vessel_service_visit_path(vessel, visit)
    end

    assert_no_difference -> { ActionMailer::Base.deliveries.size } do
      assert_no_difference -> { vessel.binder_notes.count } do
        assert_difference -> { ServiceVisitFollowUpEvent.count }, 1 do
          patch reopen_follow_up_vessel_service_visit_path(vessel, visit)
        end
      end
    end

    assert visit.reload.follow_up_open?
    assert_equal [ "completed", "reopened" ], visit.follow_up_events.pluck(:action)
  end

  test "editing a visit cannot bypass audited follow up transitions" do
    captain = create_user(email: "captain-follow-up-tamper@example.test")
    sign_in_as captain
    vessel = create_vessel
    visit = vessel.service_visits.create!(
      performed_by_user: captain,
      visit_date: Date.current,
      summary: "Original summary",
      follow_up_needed: true
    )

    patch vessel_service_visit_path(vessel, visit), params: {
      service_visit: {
        visit_date: visit.visit_date,
        summary: "Updated summary",
        follow_up_needed: "0"
      }
    }

    assert_redirected_to vessel_service_visit_path(vessel, visit)
    assert visit.reload.follow_up_open?
    assert_equal "Updated summary", visit.summary
    assert_empty visit.follow_up_events
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

  private

  def with_sized_photo_uploads(sizes)
    tempfiles = sizes.each_with_index.map do |size, index|
      tempfile = Tempfile.new([ "service-visit-photo-#{index}", ".jpg" ])
      tempfile.binmode
      tempfile.write(file_fixture("sample.jpg").binread)
      tempfile.truncate(size)
      tempfile.rewind
      tempfile
    end

    uploads = tempfiles.map { |tempfile| Rack::Test::UploadedFile.new(tempfile.path, "image/jpeg", true) }
    yield uploads
  ensure
    tempfiles&.each(&:close!)
  end

  def verified_owner(email:)
    owner = create_user(email:, role: "owner")
    owner.update!(email_verification_sent_at: 1.hour.ago, email_verified_at: Time.current)
    owner
  end
end
