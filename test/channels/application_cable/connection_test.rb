require "test_helper"

class ApplicationCable::ConnectionTest < ActionCable::Connection::TestCase
  tests ApplicationCable::Connection

  test "connects with a valid active session" do
    user = create_user(email: "cable-valid@example.test")
    active_session = create_session(user)
    cookies.signed[:session_id] = active_session.id

    connect

    assert_equal user, connection.current_user
  end

  test "rejects idle expired absolute expired legacy inactive and revoked sessions" do
    user = create_user(email: "cable-invalid@example.test", role: "captain")

    idle_expired = create_session(user)
    idle_expired.update!(last_seen_at: 12.hours.ago)
    assert_rejects(idle_expired)

    absolute_expired = create_session(user)
    absolute_expired.update!(expires_at: Time.current)
    assert_rejects(absolute_expired)

    legacy = user.sessions.create!(user_agent: "Legacy")
    assert_rejects(legacy)

    inactive = create_session(user)
    user.update!(active: false)
    assert_rejects(inactive)

    user.update!(active: true)
    revoked = create_session(user)
    revoked.destroy!
    assert_rejects(revoked)
  end

  test "an established connection remains identified after later session revocation" do
    user = create_user(email: "cable-established@example.test")
    active_session = create_session(user)
    cookies.signed[:session_id] = active_session.id
    connect

    active_session.destroy!

    assert_equal user, connection.current_user
  end

  private

  def create_session(user)
    Session.create_for!(user:, user_agent: "Cable browser", ip_address: "192.0.2.40")
  end

  def assert_rejects(session)
    cookies.signed[:session_id] = session.id
    assert_reject_connection { connect }
  end
end
