require "test_helper"

class Mfa::PolicyTest < ActiveSupport::TestCase
  test "enrolled Users and pending re-enrollment always require MFA" do
    enrolled_owner = enrolled_user(email: "policy-enrolled-owner@example.test", role: "owner")
    reenrolling_admin = enrolled_user(email: "policy-reenrolling-admin@example.test", role: "admin")
    reenrolling_admin.reset_mfa_for_reenrollment!

    assert Mfa::Policy.required_for_sign_in?(enrolled_owner)
    assert Mfa::Policy.required_for_sign_in?(reenrolling_admin)
  end

  test "first-time pending Owner setup requires MFA until completion or cancellation" do
    owner = create_user(email: "policy-pending-owner@example.test", role: "owner")
    owner.begin_mfa_enrollment!

    assert Mfa::Policy.required_for_sign_in?(owner)
  end

  test "first-time unenrolled Owner does not require MFA" do
    owner = create_user(email: "policy-unenrolled-owner@example.test", role: "owner")

    assert_not Mfa::Policy.required_for_sign_in?(owner)
  end

  test "first-time pending privileged setup requires MFA and cannot be cancelled" do
    admin = create_user(email: "policy-pending-admin@example.test", role: "admin")
    admin.begin_mfa_enrollment!

    assert Mfa::Policy.required_for_sign_in?(admin)
    assert_not admin.mfa_enrollment_cancellable?
  end

  test "unenrolled privileged Users require MFA" do
    admin = create_user(email: "policy-admin@example.test", role: "admin")
    captain = create_user(email: "policy-captain@example.test", role: "captain")

    assert Mfa::Policy.required_for_sign_in?(admin)
    assert Mfa::Policy.required_for_sign_in?(captain)
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
end
