require "test_helper"

class UserMfaTest < ActiveSupport::TestCase
  test "enrollment remains inactive until confirmation and stores the secret encrypted" do
    user = create_user(email: "mfa-encryption@example.test", role: "owner")

    user.begin_mfa_enrollment!
    secret = user.mfa_enrollment_secret
    ciphertext = User.connection.select_value(
      User.where(id: user.id).select(:mfa_totp_secret).to_sql
    )

    assert user.mfa_enrollment_pending?
    assert_not user.mfa_enrolled?
    assert_nil user.mfa_enrolled_at
    assert_empty user.mfa_recovery_code_digests
    assert_not_equal secret, ciphertext
    assert_not_includes ciphertext, secret

    assert_nil user.confirm_mfa_enrollment!("000000")
    assert_not user.reload.mfa_enrolled?
    assert_equal secret, user.mfa_enrollment_secret
  end

  test "confirmation creates ten hashed recovery codes and hides enrollment material" do
    user = create_user(email: "mfa-confirm@example.test", role: "owner")
    at = Time.zone.parse("2026-10-03 12:00:00")
    user.begin_mfa_enrollment!
    secret = user.mfa_enrollment_secret

    recovery_codes = user.confirm_mfa_enrollment!(totp_code(secret, at:), at:)

    assert_equal 10, recovery_codes.length
    assert_equal recovery_codes.uniq, recovery_codes
    assert recovery_codes.all? { |code| /\A(?:[0-9A-F]{4}-){7}[0-9A-F]{4}\z/.match?(code) }
    assert user.reload.mfa_enrolled?
    assert_nil user.mfa_enrollment_secret
    assert_nil user.mfa_enrollment_provisioning_uri
    assert_equal 10, user.mfa_recovery_code_digests.length
    recovery_codes.each do |code|
      assert_not_includes user.mfa_recovery_code_digests, code
      assert_not_includes user.mfa_recovery_code_digests.to_json, User.normalize_mfa_recovery_code(code)
    end
  end

  test "totp accepts common formatting and rejects an accepted timestep replay" do
    user, secret = enrolled_user(email: "mfa-totp@example.test")
    at = Time.zone.parse("2026-10-03 12:01:00")
    code = totp_code(secret, at:)
    formatted_code = " #{code.first(3)}-#{code.last(3)} "

    assert user.accept_mfa_totp!(formatted_code, at:)
    assert_not user.accept_mfa_totp!(code, at:)
    assert user.accept_mfa_totp!(totp_code(secret, at: at + 30.seconds), at: at + 30.seconds)
  end

  test "totp allows only one timestep of clock skew" do
    user, secret = enrolled_user(email: "mfa-skew@example.test")
    at = Time.zone.parse("2026-10-03 12:02:00")

    assert user.accept_mfa_totp!(totp_code(secret, at: at - 30.seconds), at:)

    other_user, other_secret = enrolled_user(email: "mfa-skew-two@example.test")
    assert_not other_user.accept_mfa_totp!(totp_code(other_secret, at: at - 60.seconds), at:)
  end

  test "recovery codes are single use and regeneration invalidates old codes" do
    user, = enrolled_user(email: "mfa-recovery@example.test")
    original_codes = user.regenerate_mfa_recovery_codes!
    formatted = " #{original_codes.first.downcase} "

    assert user.consume_mfa_recovery_code!(formatted)
    assert_equal 9, user.reload.mfa_recovery_codes_remaining
    assert_not user.consume_mfa_recovery_code!(original_codes.first)

    replacement_codes = user.regenerate_mfa_recovery_codes!
    assert_equal 10, user.reload.mfa_recovery_codes_remaining
    assert_not user.consume_mfa_recovery_code!(original_codes.second)
    assert user.consume_mfa_recovery_code!(replacement_codes.first)
  end

  test "outer transaction rollback leaves enrollment and recovery state unchanged" do
    user = create_user(email: "mfa-enrollment-rollback@example.test", role: "owner")
    at = Time.zone.parse("2026-10-03 12:03:00")
    user.begin_mfa_enrollment!
    secret = user.mfa_enrollment_secret

    assert_raises(RuntimeError) do
      User.transaction do
        user.confirm_mfa_enrollment!(totp_code(secret, at:), at:)
        raise "audit unavailable"
      end
    end
    assert user.reload.mfa_enrollment_pending?
    assert_empty user.mfa_recovery_code_digests

    codes = user.confirm_mfa_enrollment!(totp_code(secret, at: at + 30.seconds), at: at + 30.seconds)
    assert_raises(RuntimeError) do
      User.transaction do
        user.consume_mfa_recovery_code!(codes.first)
        raise "session unavailable"
      end
    end
    assert user.reload.consume_mfa_recovery_code!(codes.first)
  end

  private

  def enrolled_user(email:)
    user = create_user(email:, role: "owner")
    at = Time.zone.parse("2026-10-03 12:00:00")
    user.begin_mfa_enrollment!
    secret = user.mfa_enrollment_secret
    user.confirm_mfa_enrollment!(totp_code(secret, at:), at:)
    [ user.reload, secret ]
  end

  def totp_code(secret, at:)
    ROTP::TOTP.new(secret, issuer: "Boat Binder", digits: 6, interval: 30).at(at)
  end
end
