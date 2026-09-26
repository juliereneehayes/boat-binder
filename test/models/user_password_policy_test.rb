require "test_helper"
require "stringio"

class UserPasswordPolicyTest < ActiveSupport::TestCase
  test "new passwords require at least 15 characters and no more than 72 bytes" do
    short_user = build_user(password: "a" * 14)
    minimum_user = build_user(email: "minimum@example.test", password: "a" * 15)
    long_user = build_user(email: "long@example.test", password: "a" * 73)
    multibyte_too_long = build_user(email: "multibyte-long@example.test", password: "船" * 25)

    assert_not short_user.valid?
    assert_includes short_user.errors[:password], "is too short (minimum is 15 characters)"
    assert minimum_user.valid?
    assert_not long_user.valid?
    assert_includes long_user.errors[:password], "is too long. Please use a shorter password."
    assert_operator multibyte_too_long.password.length, :<=, User::PASSWORD_MAXIMUM_BYTES
    assert_operator multibyte_too_long.password.bytesize, :>, User::PASSWORD_MAXIMUM_BYTES
    assert_not multibyte_too_long.valid?
    assert_includes multibyte_too_long.errors[:password], "is too long. Please use a shorter password."
  end

  test "passphrases with spaces are accepted and confirmation is required" do
    passphrase = build_user(password: "many calm words together")
    unicode_passphrase = build_user(email: "unicode@example.test", password: "航海 安全 passphrase")
    missing_confirmation = build_user(email: "missing-confirmation@example.test", password: "fifteen characters", confirmation: nil)
    mismatch = build_user(email: "mismatch@example.test", password: "fifteen characters", confirmation: "a different phrase")

    assert passphrase.valid?
    assert_operator unicode_passphrase.password.bytesize, :<=, User::PASSWORD_MAXIMUM_BYTES
    assert unicode_passphrase.valid?
    assert_not missing_confirmation.valid?
    assert_includes missing_confirmation.errors[:password_confirmation], "can't be blank"
    assert_not mismatch.valid?
    assert_includes mismatch.errors[:password_confirmation], "doesn't match Password"
  end

  test "compromised passwords are rejected with a generic message" do
    user = build_user(password: "known breached password")
    user.password_compromise_checker = ->(_password) { true }

    assert_not user.valid?
    assert_includes user.errors[:password], User::COMPROMISED_PASSWORD_MESSAGE
  end

  test "assigning another password runs a fresh compromised-password check" do
    user = build_user(password: "first candidate password")
    user.password_compromise_checker = ->(password) { password.start_with?("first") }

    assert_not user.valid?

    user.password = "second candidate password"
    user.password_confirmation = "second candidate password"
    assert user.valid?
  end

  test "an availability failure does not block a locally valid password" do
    logger = ActiveSupport::Logger.new(StringIO.new)
    client = Object.new
    client.define_singleton_method(:fetch) do |_prefix|
      raise CompromisedPasswordChecker::AvailabilityError, "service unavailable"
    end
    user = build_user(password: "available local passphrase")
    user.password_compromise_checker = lambda do |password|
      CompromisedPasswordChecker.call(password, client:, logger:)
    end

    assert user.valid?
  end

  test "ordinary updates do not run the compromised-password lookup" do
    user = create_user(email: "ordinary-update@example.test")
    user.password_compromise_checker = ->(_password) { flunk "password lookup should not run" }

    assert user.update(name: "Updated Name")
  end

  test "legacy short-password digests still authenticate" do
    user = create_user(email: "legacy-password@example.test")
    legacy_password = "short"

    # This emulates a digest created before the new-assignment policy. Keep the
    # validation bypass confined to this backwards-compatibility regression.
    user.update_column(:password_digest, BCrypt::Password.create(legacy_password))

    assert user.reload.authenticate(legacy_password)
    assert user.update(name: "Legacy User")
  end

  private

  def build_user(password:, email: "password-policy@example.test", confirmation: password)
    User.new(
      email_address: email,
      password:,
      password_confirmation: confirmation,
      role: "captain",
      active: true
    )
  end
end
