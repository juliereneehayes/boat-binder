require "test_helper"
require "stringio"

class MfaSettingsTest < ActionDispatch::IntegrationTest
  test "owner enrollment does not alter account or tenant authorization" do
    owner = create_user(email: "mfa-account-owner@example.test", role: "owner")
    account = create_account(name: "MFA Owner Account")
    other_account = create_account(name: "Other MFA Account")
    membership = create_account_membership(user: owner, account:, access_level: "editor")
    sign_in_as(owner)

    post settings_mfa_enrollment_path, params: { user_id: create_user(email: "ignored-mfa-user@example.test").id }
    secret = owner.reload.mfa_enrollment_secret
    patch settings_mfa_enrollment_path, params: {
      user_id: "ignored",
      mfa: { code: current_totp(secret) }
    }

    assert_response :success
    assert_includes response.headers["Cache-Control"], "no-store"
    assert owner.reload.mfa_enrolled?
    assert_equal [ account.id ], owner.account_memberships.active.pluck(:account_id)
    assert_equal "editor", membership.reload.access_level
    assert_not_includes owner.active_account_ids.pluck(:id), other_account.id
  end

  test "recovery-code regeneration replaces every old code and audits no credential material" do
    owner, _, old_codes = enrolled_user(email: "mfa-regenerate@example.test", role: "owner")
    complete_mfa_sign_in(owner)

    get settings_path
    assert_response :success
    assert_select "form[action='#{settings_mfa_recovery_codes_path}'][data-turbo='false']", count: 1

    assert_difference -> { SecurityAuditEvent.count }, 1 do
      post settings_mfa_recovery_codes_path, params: {
        user_id: create_user(email: "ignored-regeneration-user@example.test").id,
        mfa: { current_password: TEST_PASSWORD }
      }
    end

    assert_response :success
    assert_includes response.headers["Cache-Control"], "no-store"
    assert_select "ol li", count: 10
    rendered_codes = css_select("ol li code").map { |element| element.text.strip }
    assert_equal 10, rendered_codes.length
    assert_not_equal old_codes.sort, rendered_codes.sort
    owner.reload
    assert_not owner.consume_mfa_recovery_code!(old_codes.first)
    assert_nil response.location
    rendered_codes.each do |code|
      assert_not_includes owner.attributes.to_json, code
      assert_not_includes request.original_url, code
    end

    event = SecurityAuditEvent.order(:id).last
    assert_equal "authentication.mfa_recovery_codes_regenerated", event.action
    assert_equal owner.id, event.actor_user_id
    assert_equal owner.id, event.target_id
    assert_nil event.source_ip
    rendered_codes.each { |code| assert_not_includes event.attributes.to_json, code }
  end

  test "invalid password cannot regenerate codes or affect another user" do
    owner, _, old_codes = enrolled_user(email: "mfa-regenerate-denied@example.test", role: "owner")
    other, = enrolled_user(email: "mfa-regenerate-other@example.test", role: "owner")
    original_digests = owner.mfa_recovery_code_digests
    other_digests = other.mfa_recovery_code_digests
    complete_mfa_sign_in(owner)

    assert_no_difference -> { SecurityAuditEvent.count } do
      post settings_mfa_recovery_codes_path, params: {
        user_id: other.id,
        mfa: { current_password: "incorrect password" }
      }
    end

    assert_redirected_to settings_path(anchor: "security")
    assert_equal original_digests, owner.reload.mfa_recovery_code_digests
    assert_equal other_digests, other.reload.mfa_recovery_code_digests
    assert owner.consume_mfa_recovery_code!(old_codes.first)
  end

  test "reset starts restricted re-enrollment revokes every session and records an event" do
    user, old_secret, = enrolled_user(email: "mfa-reset@example.test", role: "admin")
    complete_mfa_sign_in(user)
    other_session = Session.create_for!(user:, user_agent: "Other browser", ip_address: "192.0.2.80")

    assert_difference -> { SecurityAuditEvent.where(action: "authentication.mfa_reenrollment_started").count }, 1 do
      post settings_mfa_reenrollment_path, params: { mfa: { current_password: TEST_PASSWORD } }
    end

    assert_redirected_to settings_mfa_enrollment_path
    assert_empty user.sessions.reload
    assert_not Session.exists?(other_session.id)
    assert cookies[:session_id].blank?
    assert user.reload.mfa_enrollment_pending?
    assert_not_equal old_secret, user.mfa_enrollment_secret
    assert_empty user.mfa_recovery_code_digests

    get root_path
    assert_redirected_to new_session_path
    get settings_mfa_enrollment_path
    assert_response :success
    assert_includes response.body, user.mfa_enrollment_secret
    event = SecurityAuditEvent.where(action: "authentication.mfa_reenrollment_started").order(:id).last
    assert_nil event.source_ip
  end

  test "recovery-code regeneration password re-prompt is throttled per user" do
    owner, = enrolled_user(email: "mfa-regeneration-throttle@example.test", role: "owner")
    complete_mfa_sign_in(owner)

    with_password_rate_limit_store do
      5.times do
        post settings_mfa_recovery_codes_path, params: { mfa: { current_password: "wrong password" } }
        assert_equal MfaRecoveryCodesController::FAILURE_MESSAGE, flash[:alert]
      end

      post settings_mfa_recovery_codes_path, params: { mfa: { current_password: "wrong password" } }
      assert_redirected_to settings_path(anchor: "security")
      assert_equal MfaRecoveryCodesController::THROTTLED_MESSAGE, flash[:alert]
      assert owner.reload.mfa_enrolled?
    end
  end

  test "re-enrollment password re-prompt is throttled per user" do
    owner, = enrolled_user(email: "mfa-reenrollment-throttle@example.test", role: "owner")
    complete_mfa_sign_in(owner)
    original_secret = owner.mfa_totp_secret

    with_password_rate_limit_store do
      5.times do
        post settings_mfa_reenrollment_path, params: { mfa: { current_password: "wrong password" } }
        assert_equal MfaReenrollmentsController::FAILURE_MESSAGE, flash[:alert]
      end

      post settings_mfa_reenrollment_path, params: { mfa: { current_password: "wrong password" } }
      assert_redirected_to settings_path(anchor: "security")
      assert_equal MfaReenrollmentsController::THROTTLED_MESSAGE, flash[:alert]
      assert_equal original_secret, owner.reload.mfa_totp_secret
      assert owner.mfa_enrolled?
    end
  end

  test "MFA secrets and submitted codes are filtered from request logs" do
    user, secret, = enrolled_user(email: "mfa-logging@example.test", role: "captain")
    code = current_totp(secret)

    logs = capture_request_logs do
      post session_path, params: { email_address: user.email_address, password: TEST_PASSWORD }
      post mfa_challenge_path, params: { mfa: { code: } }
    end

    assert_includes logs, "[FILTERED]"
    assert_not_includes logs, TEST_PASSWORD
    assert_not_includes logs, code
    assert_not_includes logs, secret
  end

  test "enrollment audit failure rolls back activation and recovery-code creation" do
    owner = create_user(email: "mfa-audit-rollback@example.test", role: "owner")
    sign_in_as(owner)
    post settings_mfa_enrollment_path
    secret = owner.reload.mfa_enrollment_secret

    replacement = ->(**) { raise "audit unavailable" }
    singleton_class = SecurityAudit::Recorder.singleton_class
    original = singleton_class.instance_method(:record!)
    singleton_class.define_method(:record!, replacement)

    assert_raises(RuntimeError) do
      patch settings_mfa_enrollment_path, params: { mfa: { code: current_totp(secret) } }
    end

    assert owner.reload.mfa_enrollment_pending?
    assert_empty owner.mfa_recovery_code_digests
  ensure
    singleton_class&.define_method(:record!, original) if original
  end

  private

  def enrolled_user(email:, role:)
    user = create_user(email:, role:)
    user.begin_mfa_enrollment!
    secret = user.mfa_enrollment_secret
    enrollment_time = 1.minute.ago
    recovery_codes = user.confirm_mfa_enrollment!(
      ROTP::TOTP.new(secret, issuer: "Boat Binder", digits: 6, interval: 30).at(enrollment_time),
      at: enrollment_time
    )
    [ user.reload, secret, recovery_codes ]
  end

  def complete_mfa_sign_in(user)
    post session_path, params: { email_address: user.email_address, password: TEST_PASSWORD }
    secret = user.reload.mfa_totp_secret
    travel 31.seconds if user.mfa_last_accepted_timestep == Time.current.to_i / 30
    post mfa_challenge_path, params: { mfa: { code: current_totp(secret) } }
    assert_redirected_to root_path
  end

  def current_totp(secret)
    ROTP::TOTP.new(secret, issuer: "Boat Binder", digits: 6, interval: 30).now
  end

  def capture_request_logs
    output = StringIO.new
    logger = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(output))
    original_logger = Rails.logger
    original_action_controller_logger = ActionController::Base.logger
    Rails.logger = logger
    ActionController::Base.logger = logger
    yield
    output.string
  ensure
    Rails.logger = original_logger
    ActionController::Base.logger = original_action_controller_logger
  end

  def with_password_rate_limit_store(&)
    Mfa::PasswordReauthenticationRateLimit.with_store(ActiveSupport::Cache::MemoryStore.new, &)
  end
end
