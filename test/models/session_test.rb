require "test_helper"

class SessionTest < ActiveSupport::TestCase
  setup do
    @now = Time.zone.parse("2026-09-27 12:00:00")
  end

  test "owner policy uses fourteen day idle and thirty day absolute lifetimes" do
    owner = create_user(email: "session-owner@example.test", role: "owner")

    assert_equal 14.days, Session::Policy.idle_timeout_for(owner)
    assert_equal 30.days, Session::Policy.absolute_lifetime_for(owner)
  end

  test "admin and captain policy uses twelve hour idle and seven day absolute lifetimes" do
    admin = create_user(email: "session-admin@example.test", role: "admin")
    captain = create_user(email: "session-captain@example.test", role: "captain")

    [ admin, captain ].each do |user|
      assert_equal 12.hours, Session::Policy.idle_timeout_for(user)
      assert_equal 7.days, Session::Policy.absolute_lifetime_for(user)
    end
  end

  test "creation records activity and role based absolute expiration" do
    owner = create_user(email: "created-owner@example.test", role: "owner")
    captain = create_user(email: "created-captain@example.test", role: "captain")

    owner_session = create_session(owner, now: @now)
    captain_session = create_session(captain, now: @now)

    assert_equal @now, owner_session.last_seen_at
    assert_equal @now + 30.days, owner_session.expires_at
    assert_equal @now, captain_session.last_seen_at
    assert_equal @now + 7.days, captain_session.expires_at
  end

  test "validity rejects exact idle and absolute expiration boundaries" do
    owner = create_user(email: "boundary-owner@example.test", role: "owner")
    idle_session = create_session(owner, now: @now - 14.days)
    idle_session.update_columns(expires_at: @now + 1.day)
    absolute_session = create_session(owner, now: @now - 1.day)
    absolute_session.update_columns(expires_at: @now)

    assert_not idle_session.reload.valid_at?(@now)
    assert_not absolute_session.reload.valid_at?(@now)

    idle_session.update_columns(last_seen_at: @now - 14.days + 1.second)
    absolute_session.update_columns(expires_at: @now + 1.second)

    assert idle_session.reload.valid_at?(@now)
    assert absolute_session.reload.valid_at?(@now)
  end

  test "legacy null lifecycle inactive and expired sessions fail closed and are destroyed" do
    active_user = create_user(email: "invalid-session@example.test", role: "owner")
    inactive_user = create_user(email: "inactive-session@example.test", role: "owner", active: false)
    legacy_session = active_user.sessions.create!(user_agent: "Legacy")
    inactive_session = create_session(inactive_user, now: @now)
    expired_session = create_session(active_user, now: @now - 31.days)

    assert_nil Session.authenticate(legacy_session.id, now: @now)
    assert_nil Session.authenticate(inactive_session.id, now: @now)
    assert_nil Session.authenticate(expired_session.id, now: @now)
    assert_not Session.exists?(legacy_session.id)
    assert_not Session.exists?(inactive_session.id)
    assert_not Session.exists?(expired_session.id)
  end

  test "activity touch occurs only at the interval and never extends absolute expiration" do
    user = create_user(email: "touch-session@example.test", role: "owner")
    session = create_session(user, now: @now)
    expiration = session.expires_at

    assert_equal session, Session.authenticate(session.id, now: @now + 15.minutes - 1.second)
    assert_equal @now, session.reload.last_seen_at

    assert_equal session, Session.authenticate(session.id, now: @now + 15.minutes)
    assert_equal @now + 15.minutes, session.reload.last_seen_at
    assert_equal expiration, session.expires_at
  end

  private

  def create_session(user, now:)
    Session.create_for!(user:, user_agent: "Test browser", ip_address: "192.0.2.1", now:)
  end
end
