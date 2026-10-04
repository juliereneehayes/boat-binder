require "test_helper"

class Mfa::PolicyTest < ActiveSupport::TestCase
  test "enrolled Users and pending re-enrollment always require MFA" do
    enrolled_owner = enrolled_user(email: "policy-enrolled-owner@example.test", role: "owner")
    reenrolling_admin = enrolled_user(email: "policy-reenrolling-admin@example.test", role: "admin")
    reenrolling_admin.reset_mfa_for_reenrollment!

    [ false, true ].each do |enforcement|
      Mfa::Policy.with_privileged_enforcement(enforcement) do
        assert Mfa::Policy.required_for_sign_in?(enrolled_owner)
        assert Mfa::Policy.required_for_sign_in?(reenrolling_admin)
      end
    end
  end

  test "first-time pending Owner setup requires MFA until completion or cancellation" do
    owner = create_user(email: "policy-pending-owner@example.test", role: "owner")
    owner.begin_mfa_enrollment!

    [ false, true ].each do |enforcement|
      Mfa::Policy.with_privileged_enforcement(enforcement) do
        assert Mfa::Policy.required_for_sign_in?(owner)
      end
    end
  end

  test "first-time pending privileged setup follows the enforcement flag" do
    admin = create_user(email: "policy-pending-admin@example.test", role: "admin")
    admin.begin_mfa_enrollment!

    Mfa::Policy.with_privileged_enforcement(false) do
      assert_not Mfa::Policy.required_for_sign_in?(admin)
      assert admin.mfa_enrollment_cancellable?
    end
    Mfa::Policy.with_privileged_enforcement(true) do
      assert Mfa::Policy.required_for_sign_in?(admin)
      assert_not admin.mfa_enrollment_cancellable?
    end
  end

  test "unenrolled privileged sign-in follows the enforcement flag" do
    captain = create_user(email: "policy-captain@example.test", role: "captain")

    Mfa::Policy.with_privileged_enforcement(false) do
      assert_not Mfa::Policy.required_for_sign_in?(captain)
    end
    Mfa::Policy.with_privileged_enforcement(true) do
      assert Mfa::Policy.required_for_sign_in?(captain)
    end
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
