require "test_helper"

class ServiceVisitSummaryResendTest < ActionDispatch::IntegrationTest
  setup do
    ActionMailer::Base.deliveries.clear
  end

  teardown do
    ActionMailer::Base.deliveries.clear
  end

  test "admin resends to a corrected primary contact without changing the visit" do
    account = create_account(name: "Corrected Recipient")
    contact = account.contacts.create!(name: "Primary Owner", role: "Owner")
    admin = create_user(email: "summary-resend-admin@example.test", role: "admin")
    vessel = create_vessel(account:, name: "Sea Glass")
    sign_in_as admin

    post vessel_service_visits_path(vessel), params: {
      service_visit: { visit_date: Date.current, summary: "Recipient will be corrected." }
    }
    visit = ServiceVisit.find_by!(summary: "Recipient will be corrected.")
    original_attributes = visit.attributes
    automatic_event = summary_delivery_events(visit).last

    assert_equal "denied", automatic_event.outcome
    assert_redirected_to vessel_service_visit_path(vessel, visit)

    contact.update!(email: "corrected-owner@example.test")

    assert_no_difference -> { ServiceVisit.count } do
      assert_difference -> { summary_resend_events(visit).count }, 1 do
        assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
          post resend_summary_vessel_service_visit_path(vessel, visit)
        end
      end
    end

    assert_redirected_to vessel_service_visit_path(vessel, visit)
    assert_equal "Summary email sent.", flash[:notice]
    assert_equal [ "corrected-owner@example.test" ], ActionMailer::Base.deliveries.last.to
    assert_equal original_attributes, visit.reload.attributes

    event = summary_resend_events(visit).last
    assert_equal "succeeded", event.outcome
    assert_equal admin, event.actor_user
    assert_equal account, event.account
    assert_equal "ServiceVisit", event.target_type
    assert_equal visit.id, event.target_id
    assert event.request_id.present?
    assert_empty event.changed_fields
    assert_not_includes event.attributes.to_json, contact.email
    assert_not_includes event.attributes.to_json, visit.summary
  end

  test "captain resends with the existing authorized full report link policy" do
    account = create_account(name: "Authorized Link")
    account.contacts.create!(name: "Primary Owner", email: "linked-owner@example.test", role: "Owner")
    qualify_self_managed_subscription(account)
    owner = verified_owner(email: "linked-owner@example.test")
    create_account_membership(user: owner, account:)
    captain = create_user(email: "summary-resend-captain@example.test")
    vessel = create_vessel(account:, name: "Blue Meridian")
    visit = create_visit(vessel:, performed_by: captain)
    sign_in_as captain

    post resend_summary_vessel_service_visit_path(vessel, visit)

    assert_redirected_to vessel_service_visit_path(vessel, visit)
    assert_equal "Summary email sent.", flash[:notice]
    mail = ActionMailer::Base.deliveries.last
    expected_url = report_vessel_service_visit_url(
      vessel,
      visit,
      **Rails.application.config.action_mailer.default_url_options
    )
    assert_includes mail.html_part.body.decoded, expected_url
    assert_includes mail.text_part.body.decoded, expected_url
    assert_equal "succeeded", summary_resend_events(visit).last.outcome
  end

  test "manual resend is hidden from owners and rejects owner and crafted nested requests" do
    account = create_account(name: "Owner Account")
    other_account = create_account(name: "Other Account")
    qualify_self_managed_subscription(account)
    owner = verified_owner(email: "summary-resend-owner@example.test")
    create_account_membership(user: owner, account:, access_level: "editor")
    captain = create_user(email: "summary-resend-scope-captain@example.test")
    vessel = create_vessel(account:, name: "Owner Vessel")
    other_vessel = create_vessel(account: other_account, name: "Other Vessel")
    visit = create_visit(vessel:, performed_by: captain)
    other_visit = create_visit(vessel: other_vessel, performed_by: captain)
    sign_in_as owner

    get vessel_service_visit_path(vessel, visit)

    assert_response :success
    assert_select "form[action=?]", resend_summary_vessel_service_visit_path(vessel, visit), count: 0

    assert_no_difference -> { ActionMailer::Base.deliveries.size } do
      assert_no_difference -> { summary_resend_events(visit).count } do
        post resend_summary_vessel_service_visit_path(vessel, visit)
      end
    end
    assert_access_denied_redirect

    post resend_summary_vessel_service_visit_path(vessel, other_visit)
    assert_access_denied_redirect

    post resend_summary_vessel_service_visit_path(other_vessel, other_visit)
    assert_response :not_found
    assert_empty summary_resend_events(other_visit)
  end

  test "nested visit lookup prevents cross vessel resend by an internal user" do
    captain = create_user(email: "summary-resend-nested-captain@example.test")
    first_vessel = create_vessel(name: "First Vessel")
    second_vessel = create_vessel(account: create_account(name: "Second Account"), name: "Second Vessel")
    second_visit = create_visit(vessel: second_vessel, performed_by: captain)
    sign_in_as captain

    assert_no_difference -> { ActionMailer::Base.deliveries.size } do
      post resend_summary_vessel_service_visit_path(first_vessel, second_visit)
    end

    assert_response :not_found
    assert_empty summary_resend_events(second_visit)
  end

  test "missing and invalid current recipients fail closed and remain retryable" do
    account = create_account(name: "Unavailable Recipient")
    contact = account.contacts.create!(name: "Primary Owner", role: "Owner")
    captain = create_user(email: "summary-resend-no-recipient@example.test")
    vessel = create_vessel(account:, name: "No Recipient")
    visit = create_visit(vessel:, performed_by: captain)
    sign_in_as captain

    2.times do
      assert_difference -> { summary_resend_events(visit).where(outcome: "denied").count }, 1 do
        assert_no_difference -> { ActionMailer::Base.deliveries.size } do
          post resend_summary_vessel_service_visit_path(vessel, visit)
        end
      end
      assert_equal "Add a valid primary owner contact email before sending the summary.", flash[:alert]
    end

    contact.update_column(:email, "invalid-address")

    assert_difference -> { summary_resend_events(visit).where(outcome: "denied").count }, 1 do
      assert_no_difference -> { ActionMailer::Base.deliveries.size } do
        post resend_summary_vessel_service_visit_path(vessel, visit)
      end
    end
    assert_equal "Add a valid primary owner contact email before sending the summary.", flash[:alert]
  end

  test "delivery failure is safely reported, audited, and immediately retryable" do
    account = create_account(name: "Retry Delivery")
    account.contacts.create!(name: "Primary Owner", email: "retry-owner@example.test", role: "Owner")
    captain = create_user(email: "summary-resend-retry-captain@example.test")
    vessel = create_vessel(account:, name: "Retry Vessel")
    visit = create_visit(vessel:, performed_by: captain)
    failed_delivery = Object.new
    failed_delivery.define_singleton_method(:deliver_now) do
      raise Errno::ECONNREFUSED, "synthetic SMTP connection failure"
    end
    sign_in_as captain
    original_summary = ServiceVisitMailer.method(:summary)

    begin
      ServiceVisitMailer.define_singleton_method(:summary) { |_visit, _recipient| failed_delivery }
      assert_difference -> { summary_resend_events(visit).where(outcome: "failed").count }, 1 do
        post resend_summary_vessel_service_visit_path(vessel, visit)
      end
    ensure
      ServiceVisitMailer.define_singleton_method(:summary, original_summary)
    end

    assert_redirected_to vessel_service_visit_path(vessel, visit)
    assert_equal "Summary email could not be sent. Please try again.", flash[:alert]

    assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
      post resend_summary_vessel_service_visit_path(vessel, visit)
    end
    assert_equal "Summary email sent.", flash[:notice]
    assert_equal %w[failed succeeded], summary_resend_events(visit).order(:id).pluck(:outcome)
  end

  test "successful manual resend suppresses rapid repeats but allows a later resend" do
    account = create_account(name: "Repeat Safeguard")
    account.contacts.create!(name: "Primary Owner", email: "repeat-owner@example.test", role: "Owner")
    captain = create_user(email: "summary-resend-repeat-captain@example.test")
    vessel = create_vessel(account:, name: "Repeat Vessel")
    visit = create_visit(vessel:, performed_by: captain)
    sign_in_as captain

    post resend_summary_vessel_service_visit_path(vessel, visit)

    assert_difference -> { summary_resend_events(visit).where(outcome: "denied").count }, 1 do
      assert_no_difference -> { ActionMailer::Base.deliveries.size } do
        post resend_summary_vessel_service_visit_path(vessel, visit)
      end
    end
    assert_equal "Summary email was recently sent. Please wait before sending it again.", flash[:alert]

    travel ServiceVisitsController::MANUAL_SUMMARY_RESEND_COOLDOWN + 1.second do
      assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
        post resend_summary_vessel_service_visit_path(vessel, visit)
      end
    end

    assert_equal %w[succeeded denied succeeded], summary_resend_events(visit).order(:id).pluck(:outcome)
  end

  test "admin and captain see the manual resend action" do
    account = create_account(name: "Visible Resend")
    vessel = create_vessel(account:)
    visit = create_visit(vessel:, performed_by: create_user(email: "summary-resend-creator@example.test"))

    [
      create_user(email: "summary-resend-visible-admin@example.test", role: "admin"),
      create_user(email: "summary-resend-visible-captain@example.test")
    ].each do |internal_user|
      sign_in_as internal_user
      get vessel_service_visit_path(vessel, visit)

      assert_response :success
      assert_select "form[action=?][method='post']", resend_summary_vessel_service_visit_path(vessel, visit)
      assert_select "form[action=?] button", resend_summary_vessel_service_visit_path(vessel, visit),
        text: "Resend summary email"
    end
  end

  private

  def create_visit(vessel:, performed_by:)
    vessel.service_visits.create!(
      performed_by_user: performed_by,
      visit_date: Date.current,
      summary: "Existing service visit summary."
    )
  end

  def summary_delivery_events(visit)
    SecurityAuditEvent.where(
      action: "service_visit.summary_delivery",
      target_type: "ServiceVisit",
      target_id: visit.id
    )
  end

  def summary_resend_events(visit)
    SecurityAuditEvent.where(
      action: ServiceVisitsController::MANUAL_SUMMARY_RESEND_AUDIT_ACTION,
      target_type: "ServiceVisit",
      target_id: visit.id
    )
  end

  def verified_owner(email:)
    owner = create_user(email:, role: "owner")
    owner.update!(email_verification_sent_at: 1.hour.ago, email_verified_at: Time.current)
    owner
  end
end
