require "test_helper"
require "timeout"

class ServiceVisitSummaryResendConcurrencyTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  setup do
    suffix = SecureRandom.hex(6)
    @account = create_account(name: "Concurrent Summary Resend #{suffix}")
    @account.contacts.create!(
      name: "Primary Owner",
      email: "concurrent-summary-owner-#{suffix}@example.test",
      role: "Owner"
    )
    @vessel = create_vessel(account: @account, name: "Concurrent Resend Vessel #{suffix}")
    @captains = 2.times.map do |index|
      create_user(email: "concurrent-summary-captain-#{suffix}-#{index}@example.test")
    end
    @visit = @vessel.service_visits.create!(
      performed_by_user: @captains.first,
      visit_date: Date.current,
      summary: "Synthetic concurrent resend summary."
    )
    @sessions = @captains.map { |captain| signed_in_session(captain) }
  end

  teardown do
    captain_ids = @captains.map(&:id)
    SecurityAuditEvent.connection.execute(
      SecurityAuditEvent.sanitize_sql_array(
        [
          <<~SQL.squish,
            DELETE FROM security_audit_events
            WHERE (target_type = ? AND target_id = ?)
              OR actor_user_id IN (?)
              OR (target_type = ? AND target_id IN (?))
          SQL
          "ServiceVisit",
          @visit.id,
          captain_ids,
          "User",
          captain_ids
        ]
      )
    )
    @visit.destroy!
    @vessel.destroy!
    @account.reload.destroy!
    @captains.each(&:destroy!)
  end

  test "concurrent manual resend requests submit only one email" do
    delivery_started = Queue.new
    release_delivery = Queue.new
    second_request_started = Queue.new
    results = Queue.new
    mailer_calls = 0
    mailer_calls_mutex = Mutex.new
    blocking_delivery = Object.new
    blocking_delivery.define_singleton_method(:deliver_now) do
      delivery_started << true
      release_delivery.pop
      true
    end
    summary_stub = lambda do |_visit, _recipient|
      mailer_calls_mutex.synchronize { mailer_calls += 1 }
      blocking_delivery
    end
    original_summary = ServiceVisitMailer.method(:summary)

    begin
      ServiceVisitMailer.define_singleton_method(:summary, summary_stub)
      first_thread = request_thread(@sessions.first, results)
      Timeout.timeout(5) { delivery_started.pop }

      second_thread = request_thread(@sessions.second, results, started: second_request_started)
      Timeout.timeout(5) { second_request_started.pop }
      sleep 0.1
      release_delivery << true

      assert first_thread.join(5), "first resend request deadlocked"
      assert second_thread.join(5), "second resend request did not resume after the row lock"
    ensure
      ServiceVisitMailer.define_singleton_method(:summary, original_summary)
      release_delivery << true if first_thread&.alive?
      first_thread&.join(1)
      second_thread&.join(1)
    end

    outcomes = 2.times.map { Timeout.timeout(5) { results.pop } }
    outcomes.each { |outcome| assert_equal 302, outcome.fetch(:status) }
    assert_equal 1, mailer_calls
    assert_equal %w[succeeded denied], resend_events.order(:id).pluck(:outcome)
    assert_equal [
      "Summary email sent.",
      "Summary email was recently sent. Please wait before sending it again."
    ], outcomes.map { |outcome| outcome.fetch(:flash) }.sort
  end

  private

  def request_thread(session, results, started: nil)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        started << true if started
        session.post resend_summary_vessel_service_visit_path(@vessel, @visit)
        results << {
          status: session.response.status,
          flash: session.request.flash[:notice] || session.request.flash[:alert]
        }
      rescue StandardError => error
        results << { error: }
      end
    end
  end

  def signed_in_session(user)
    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.post session_path, params: {
      email_address: user.email_address,
      password: TEST_PASSWORD
    }

    if session.response.location == settings_mfa_enrollment_url
      secret = user.reload.mfa_enrollment_secret
      code = ROTP::TOTP.new(
        secret,
        issuer: "Boat Binder",
        digits: User::MFA_TOTP_DIGITS,
        interval: User::MFA_TOTP_PERIOD
      ).now
      session.patch settings_mfa_enrollment_path, params: { mfa: { code: } }
    end

    session
  end

  def resend_events
    SecurityAuditEvent.where(
      action: ServiceVisitsController::MANUAL_SUMMARY_RESEND_AUDIT_ACTION,
      target_type: "ServiceVisit",
      target_id: @visit.id
    )
  end
end
