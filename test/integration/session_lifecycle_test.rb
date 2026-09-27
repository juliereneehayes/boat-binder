require "test_helper"

class SessionLifecycleTest < ActionDispatch::IntegrationTest
  test "successful sign in rotates identity and creates lifecycle bounded cookie" do
    owner = create_user(email: "rotate-session@example.test", role: "owner")

    travel_to Time.zone.parse("2026-09-27 12:00:00") do
      sign_in_as(owner)
      first_session = owner.sessions.sole

      assert_equal Time.current, first_session.last_seen_at
      assert_equal Time.current + 30.days, first_session.expires_at
      assert cookies[:session_id].present?
      assert_match(
        /expires=#{Regexp.escape(first_session.expires_at.httpdate)}/i,
        Array(response.headers["Set-Cookie"]).join
      )

      delete session_path
      sign_in_as(owner)
      second_session = owner.sessions.sole

      assert_not_equal first_session.id, second_session.id
    end
  end

  test "admin and captain sign ins use the privileged absolute lifetime" do
    admin = create_user(email: "privileged-admin-session@example.test", role: "admin")
    captain = create_user(email: "privileged-captain-session@example.test", role: "captain")

    travel_to Time.zone.parse("2026-09-27 12:00:00") do
      [ admin, captain ].each do |user|
        sign_in_as(user)

        assert_equal Time.current, user.sessions.sole.last_seen_at
        assert_equal Time.current + 7.days, user.sessions.sole.expires_at
      end
    end
  end

  test "active session authenticates and is removed on sign out" do
    user = create_user(email: "normal-session@example.test")
    sign_in_as(user)
    active_session = user.sessions.sole

    get root_path
    assert_response :success

    delete session_path
    assert_redirected_to new_session_path
    assert_not Session.exists?(active_session.id)
    assert cookies[:session_id].blank?
  end

  test "idle expired session cannot be resurrected and its cookie is cleared" do
    user = create_user(email: "idle-http-session@example.test", role: "owner")
    sign_in_as(user)
    active_session = user.sessions.sole
    active_session.update!(last_seen_at: 14.days.ago)

    get root_path

    assert_redirected_to new_session_path
    assert_not Session.exists?(active_session.id)
    assert cookies[:session_id].blank?
  end

  test "absolute expired session cannot restore authentication" do
    user = create_user(email: "absolute-http-session@example.test")
    sign_in_as(user)
    active_session = user.sessions.sole
    active_session.update!(expires_at: Time.current)

    get root_path

    assert_redirected_to new_session_path
    assert_not Session.exists?(active_session.id)
    assert cookies[:session_id].blank?
  end

  test "legacy null lifecycle and inactive user sessions are rejected" do
    user = create_user(email: "legacy-http-session@example.test")
    sign_in_as(user)
    active_session = user.sessions.sole
    active_session.update_columns(last_seen_at: nil, expires_at: nil)

    get root_path
    assert_redirected_to new_session_path
    assert_not Session.exists?(active_session.id)

    sign_in_as(user)
    inactive_session = user.sessions.sole
    user.update!(active: false)

    get root_path
    assert_redirected_to new_session_path
    assert_not Session.exists?(inactive_session.id)
  end

  test "active sessions page shows only current user sessions without identifiers" do
    user = create_user(email: "session-list@example.test", role: "owner")
    other_user = create_user(email: "other-session-list@example.test", role: "owner")
    sign_in_as(user)
    current_session = user.sessions.sole
    own_other = Session.create_for!(
      user:,
      user_agent: "Mozilla/5.0 (Macintosh) Gecko/20100101 Firefox/145.0",
      ip_address: "192.0.2.10"
    )
    other_session = Session.create_for!(
      user: other_user,
      user_agent: "Mozilla/5.0 (Windows NT 10.0) AppleWebKit/537.36 Chrome/145.0 Safari/537.36",
      ip_address: "192.0.2.11"
    )

    get active_sessions_path

    assert_response :success
    assert_select "article", count: 2
    assert_select "span", text: "Current session", count: 1
    assert_includes response.body, "Firefox"
    assert_not_includes response.body, "Chrome"
    assert_not_includes response.body, "192.0.2.10"
    assert_not_includes response.body, "session_id"
    assert_not_includes response.body, active_sessions_path + "/#{own_other.id}"
    assert Session.exists?(current_session.id)
    assert Session.exists?(other_session.id)
  end

  test "sign out other sessions is scoped to current user and preserves current session" do
    user = create_user(email: "revoke-other@example.test", role: "owner")
    other_user = create_user(email: "unrelated-revoke@example.test", role: "owner")
    sign_in_as(user)
    current_session = user.sessions.sole
    own_other = Session.create_for!(user:, user_agent: "Firefox", ip_address: "192.0.2.20")
    unrelated = Session.create_for!(user: other_user, user_agent: "Chrome", ip_address: "192.0.2.21")

    delete other_active_sessions_path, params: { user_id: other_user.id }

    assert_redirected_to active_sessions_path
    assert Session.exists?(current_session.id)
    assert_not Session.exists?(own_other.id)
    assert Session.exists?(unrelated.id)
  end

  test "password reset revokes every existing session" do
    user = create_user(email: "password-reset-revocation@example.test", role: "owner")
    first_session = Session.create_for!(user:, user_agent: "Firefox", ip_address: "192.0.2.31")
    second_session = Session.create_for!(user:, user_agent: "Chrome", ip_address: "192.0.2.32")
    token = user.password_reset_token

    put password_path(token), params: {
      password: NEW_TEST_PASSWORD,
      password_confirmation: NEW_TEST_PASSWORD
    }

    assert_redirected_to new_session_path
    assert_not Session.exists?(first_session.id)
    assert_not Session.exists?(second_session.id)
  end
end
