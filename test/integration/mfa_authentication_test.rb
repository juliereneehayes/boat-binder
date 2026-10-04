require "test_helper"

class MfaAuthenticationTest < ActionDispatch::IntegrationTest
  test "owner without MFA signs in exactly as before" do
    owner = create_user(email: "plain-owner@example.test", role: "owner")

    assert_difference -> { Session.where(user: owner).count }, 1 do
      post session_path, params: { email_address: owner.email_address, password: TEST_PASSWORD }
    end

    assert_redirected_to root_path
    assert cookies[:session_id].present?
  end

  test "owner can enroll and must complete MFA on future sign in" do
    owner = create_user(email: "enrolled-owner@example.test", role: "owner")
    sign_in_as(owner)

    post settings_mfa_enrollment_path
    assert_redirected_to settings_mfa_enrollment_path
    secret = owner.reload.mfa_enrollment_secret
    get settings_mfa_enrollment_path
    assert_response :success
    assert_includes response.body, secret
    assert_select "input[autocomplete='one-time-code'][inputmode='numeric']"

    travel_to(Time.zone.parse("2026-10-03 13:00:00")) do
      assert_difference -> { SecurityAuditEvent.where(action: "authentication.mfa_enrolled").count }, 1 do
        patch settings_mfa_enrollment_path, params: { mfa: { code: formatted_totp(secret) } }
      end
    end
    assert_response :success
    assert owner.reload.mfa_enrolled?
    enrollment_event = SecurityAuditEvent.where(action: "authentication.mfa_enrolled").order(:id).last
    assert_nil enrollment_event.source_ip
    assert_select "ol li", count: 10
    assert_not_includes response.body, secret

    delete session_path
    travel 31.seconds
    assert_no_difference -> { Session.where(user: owner).count } do
      post session_path, params: { email_address: owner.email_address, password: TEST_PASSWORD }
    end
    assert_redirected_to new_mfa_challenge_path
  end

  test "enforcement restricts unenrolled admins and captains without creating sessions" do
    %w[admin captain].each do |role|
      user = create_user(email: "unenrolled-#{role}@example.test", role:)

      with_mfa_enforcement do
        assert_no_difference -> { Session.where(user:).count } do
          post session_path, params: { email_address: user.email_address, password: TEST_PASSWORD }
        end
      end

      assert_redirected_to settings_mfa_enrollment_path
      assert user.reload.mfa_enrollment_pending?
      get root_path
      assert_redirected_to new_session_path
      assert_empty user.sessions

      delete mfa_challenge_path
      assert_redirected_to new_session_path
    end
  end

  test "privileged enrollment challenge creates the first normal session only after confirmation" do
    admin = create_user(email: "first-mfa-admin@example.test", role: "admin")

    with_challenge_store do
      with_mfa_enforcement do
        assert_no_difference -> { admin.sessions.count } do
          post session_path, params: { email_address: admin.email_address, password: TEST_PASSWORD }
        end
      end
      assert_redirected_to settings_mfa_enrollment_path

      secret = admin.reload.mfa_enrollment_secret
      get settings_mfa_enrollment_path
      assert_response :success
      assert_includes response.headers["Cache-Control"], "no-store"
      assert_includes response.body, secret

      assert_difference -> { admin.sessions.count }, 1 do
        patch settings_mfa_enrollment_path, params: { mfa: { code: current_totp(secret) } }
      end
      assert_response :success
      assert_includes response.headers["Cache-Control"], "no-store"
      assert admin.reload.mfa_enrolled?
      assert_select "ol li", count: 10

      get settings_mfa_enrollment_path
      assert_redirected_to settings_path(anchor: "security")
      assert_not_includes response.body, secret
    end
  end

  test "correct formatted TOTP creates a session while an incorrect code fails generically" do
    user, secret = enrolled_user(email: "totp-login@example.test", role: "captain")

    with_challenge_store do
      begin_mfa_sign_in(user)
      assert_no_difference -> { user.sessions.count } do
        post mfa_challenge_path, params: { mfa: { code: "000 000" } }
      end
      assert_redirected_to new_mfa_challenge_path
      assert_equal MfaChallengesController::VERIFICATION_FAILURE_MESSAGE, flash[:alert]

      assert_difference -> { user.sessions.count }, 1 do
        post mfa_challenge_path, params: { mfa: { code: formatted_totp(secret) } }
      end
      assert_redirected_to root_path
    end
  end

  test "challenge expires cannot switch users and is single use" do
    first, first_secret = enrolled_user(email: "bound-one@example.test", role: "admin")
    second, second_secret = enrolled_user(email: "bound-two@example.test", role: "admin")

    with_challenge_store do
      begin_mfa_sign_in(first)
      post mfa_challenge_path, params: {
        user_id: second.id,
        mfa: { code: current_totp(second_secret) }
      }
      assert_redirected_to new_mfa_challenge_path
      assert_empty first.sessions
      assert_empty second.sessions

      travel 11.minutes
      post mfa_challenge_path, params: { mfa: { code: current_totp(first_secret) } }
      assert_redirected_to new_session_path

      travel_back
      begin_mfa_sign_in(first)
      copied_challenge = cookies[Mfa::Challenge::COOKIE_NAME]
      post mfa_challenge_path, params: { mfa: { code: current_totp(first_secret) } }
      assert_redirected_to root_path
      delete session_path
      cookies[Mfa::Challenge::COOKIE_NAME] = copied_challenge

      assert_no_difference -> { first.sessions.count } do
        post mfa_challenge_path, params: { mfa: { code: current_totp(first_secret, at: 30.seconds.from_now) } }
      end
      assert_redirected_to new_session_path
    end
  end

  test "MFA reset invalidates copied challenges without invalidating the new enrollment challenge" do
    user, = enrolled_user(email: "stale-reset-challenge@example.test", role: "admin")

    with_challenge_store do
      begin_mfa_sign_in(user)
      old_challenge = cookies[Mfa::Challenge::COOKIE_NAME]

      Mfa::Reset.call!(user:)
      new_secret = user.reload.mfa_enrollment_secret
      post session_path, params: { email_address: user.email_address, password: TEST_PASSWORD }
      assert_redirected_to settings_mfa_enrollment_path
      new_challenge = cookies[Mfa::Challenge::COOKIE_NAME]
      assert_not_equal old_challenge, new_challenge

      cookies[Mfa::Challenge::COOKIE_NAME] = old_challenge
      assert_no_difference -> { user.sessions.count } do
        get settings_mfa_enrollment_path
      end
      assert_redirected_to new_session_path
      assert_not_includes response.body, new_secret

      cookies[Mfa::Challenge::COOKIE_NAME] = new_challenge
      get settings_mfa_enrollment_path
      assert_response :success
      assert_includes response.body, new_secret
    end
  end

  test "challenge preserves the return-to destination" do
    user, secret = enrolled_user(email: "mfa-return-to@example.test", role: "owner")

    get settings_path
    assert_redirected_to new_session_path
    begin_mfa_sign_in(user)
    post mfa_challenge_path, params: { mfa: { code: current_totp(secret) } }

    assert_redirected_to settings_url
  end

  test "MFA attempts are limited to five per challenge identity in an isolated store" do
    user, = enrolled_user(email: "mfa-throttle@example.test", role: "admin")

    with_challenge_store do
      begin_mfa_sign_in(user)
      5.times do
        post mfa_challenge_path, params: { mfa: { code: "000000" } }
        assert_equal MfaChallengesController::VERIFICATION_FAILURE_MESSAGE, flash[:alert]
      end

      post mfa_challenge_path, params: { mfa: { code: "000000" } }
      assert_redirected_to new_mfa_challenge_path
      assert_equal MfaChallengesController::THROTTLED_MESSAGE, flash[:alert]
      assert_empty user.sessions
    end
  end

  test "recovery code signs in once and records a minimized global User event" do
    user, = enrolled_user(email: "recovery-login@example.test", role: "captain")
    recovery_code = user.regenerate_mfa_recovery_codes!.first

    with_challenge_store do
      begin_mfa_sign_in(user)
      assert_difference -> { SecurityAuditEvent.count }, 1 do
        post mfa_challenge_path, params: { user_id: "ignored", mfa: { recovery_code: recovery_code.downcase } }
      end
      assert_redirected_to root_path
      event = SecurityAuditEvent.order(:id).last
      assert_equal "authentication.mfa_recovery_code_used", event.action
      assert_equal user.id, event.actor_user_id
      assert_nil event.account_id
      assert_nil event.source_ip
      assert_equal user.id, event.target_id
      assert_not_includes event.attributes.to_json, recovery_code

      delete session_path
      begin_mfa_sign_in(user)
      assert_no_difference -> { user.sessions.count } do
        post mfa_challenge_path, params: { mfa: { recovery_code: } }
      end
      assert_equal MfaChallengesController::VERIFICATION_FAILURE_MESSAGE, flash[:alert]
    end
  end

  test "pending Owner enrollment can be cancelled after password verification" do
    owner = create_user(email: "cancel-pending-owner@example.test", role: "owner")
    sign_in_as(owner)
    post settings_mfa_enrollment_path
    assert owner.reload.mfa_enrollment_pending?
    delete session_path

    post session_path, params: { email_address: owner.email_address, password: TEST_PASSWORD }
    assert_redirected_to settings_mfa_enrollment_path
    assert_no_difference -> { SecurityAuditEvent.count } do
      assert_difference -> { owner.sessions.count }, 1 do
        delete settings_mfa_enrollment_path
      end
    end

    assert_redirected_to root_path
    assert_not owner.reload.mfa_enrollment_pending?
    assert_nil owner.mfa_totp_secret
    delete session_path

    assert_difference -> { owner.sessions.count }, 1 do
      post session_path, params: { email_address: owner.email_address, password: TEST_PASSWORD }
    end
    assert_redirected_to root_path
  end

  test "privileged and enrolled Owner credentials cannot use pending enrollment cancellation" do
    admin = create_user(email: "cancel-pending-admin@example.test", role: "admin")

    with_mfa_enforcement do
      post session_path, params: { email_address: admin.email_address, password: TEST_PASSWORD }
    end
    admin_secret = admin.reload.mfa_enrollment_secret
    delete settings_mfa_enrollment_path
    assert_redirected_to settings_mfa_enrollment_path
    assert_equal MfaEnrollmentsController::CANCELLATION_DENIED_MESSAGE, flash[:alert]
    assert_equal admin_secret, admin.reload.mfa_enrollment_secret
    assert_empty admin.sessions

    delete mfa_challenge_path
    owner, = enrolled_user(email: "cancel-enrolled-owner@example.test", role: "owner")
    complete_mfa_sign_in(owner)
    delete settings_mfa_enrollment_path
    assert_redirected_to settings_path(anchor: "security")
    assert_equal MfaEnrollmentsController::CANCELLATION_DENIED_MESSAGE, flash[:alert]
    assert owner.reload.mfa_enrolled?
    assert owner.mfa_totp_secret.present?
  end

  test "role changes revoke sessions and the next login follows the new MFA policy" do
    admin = create_user(email: "mfa-role-admin@example.test", role: "admin")
    owner = create_user(email: "mfa-role-owner@example.test", role: "owner", name: "Role Owner")
    owner_session = Session.create_for!(
      user: owner,
      user_agent: "Owner browser",
      ip_address: "192.0.2.90"
    )
    sign_in_as(admin)

    patch admin_user_path(owner), params: { user: {
      name: owner.name,
      email_address: owner.email_address,
      role: "captain",
      active: "1",
      password: "",
      password_confirmation: "",
      account_ids: []
    } }

    assert_redirected_to admin_users_path
    assert owner.reload.captain?
    assert_not Session.exists?(owner_session.id)
    delete session_path

    with_mfa_enforcement do
      assert_no_difference -> { owner.sessions.count } do
        post session_path, params: { email_address: owner.email_address, password: TEST_PASSWORD }
      end
    end
    assert_redirected_to settings_mfa_enrollment_path

    enrolled_captain, = enrolled_user(email: "mfa-role-captain@example.test", role: "captain")
    captain_session = Session.create_for!(
      user: enrolled_captain,
      user_agent: "Captain browser",
      ip_address: "192.0.2.91"
    )
    sign_in_as(admin)
    patch admin_user_path(enrolled_captain), params: { user: {
      name: enrolled_captain.name,
      email_address: enrolled_captain.email_address,
      role: "owner",
      active: "1",
      password: "",
      password_confirmation: "",
      account_ids: []
    } }

    assert enrolled_captain.reload.owner?
    assert enrolled_captain.mfa_enrolled?
    assert_not Session.exists?(captain_session.id)
    delete session_path
    post session_path, params: { email_address: enrolled_captain.email_address, password: TEST_PASSWORD }
    assert_redirected_to new_mfa_challenge_path
    assert_empty enrolled_captain.sessions
  end

  private

  def enrolled_user(email:, role:)
    user = create_user(email:, role:)
    user.begin_mfa_enrollment!
    secret = user.mfa_enrollment_secret
    enrollment_time = 1.minute.ago
    user.confirm_mfa_enrollment!(current_totp(secret, at: enrollment_time), at: enrollment_time)
    [ user.reload, secret ]
  end

  def begin_mfa_sign_in(user)
    post session_path, params: { email_address: user.email_address, password: TEST_PASSWORD }
    assert_redirected_to new_mfa_challenge_path
  end

  def complete_mfa_sign_in(user)
    begin_mfa_sign_in(user)
    post mfa_challenge_path, params: { mfa: { code: current_totp(user.mfa_totp_secret) } }
    assert_redirected_to root_path
  end

  def current_totp(secret, at: Time.current)
    ROTP::TOTP.new(secret, issuer: "Boat Binder", digits: 6, interval: 30).at(at)
  end

  def formatted_totp(secret)
    code = current_totp(secret)
    " #{code.first(3)}-#{code.last(3)} "
  end

  def with_mfa_enforcement(&)
    Mfa::Policy.with_privileged_enforcement(true, &)
  end

  def with_challenge_store(&)
    Mfa::Challenge.with_store(ActiveSupport::Cache::MemoryStore.new, &)
  end
end
