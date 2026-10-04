require "test_helper"

class Mfa::EnforcementActivationTest < ActiveSupport::TestCase
  test "revokes only unenrolled privileged sessions" do
    admin = create_user(email: "activation-admin@example.test", role: "admin")
    captain = create_user(email: "activation-captain@example.test", role: "captain")
    enrolled_admin = enrolled_user(email: "activation-enrolled-admin@example.test", role: "admin")
    owner = create_user(email: "activation-owner@example.test", role: "owner")
    pending_owner = create_user(email: "activation-pending-owner@example.test", role: "owner")
    pending_owner.begin_mfa_enrollment!

    revoked_sessions = [ session_for(admin), session_for(captain) ]
    preserved_sessions = [ session_for(enrolled_admin), session_for(owner), session_for(pending_owner) ]

    result = Mfa::EnforcementActivation.revoke_unenrolled_privileged_sessions!

    assert_equal 2, result.user_count
    assert_equal 2, result.session_count
    revoked_sessions.each { |session| assert_not Session.exists?(session.id) }
    preserved_sessions.each { |session| assert Session.exists?(session.id) }
    assert_equal 0, Mfa::EnforcementActivation.remaining_session_count

    rerun = Mfa::EnforcementActivation.revoke_unenrolled_privileged_sessions!
    assert_equal 0, rerun.session_count
    assert_equal 0, Mfa::EnforcementActivation.remaining_session_count
    preserved_sessions.each { |session| assert Session.exists?(session.id) }
  end

  private

  def enrolled_user(email:, role:)
    user = create_user(email:, role:)
    user.begin_mfa_enrollment!
    secret = user.mfa_enrollment_secret
    user.confirm_mfa_enrollment!(
      ROTP::TOTP.new(secret, issuer: "Boat Binder", digits: 6, interval: 30).now
    )
    user
  end

  def session_for(user)
    Session.create_for!(user:, user_agent: "Activation test", ip_address: "192.0.2.100")
  end
end
