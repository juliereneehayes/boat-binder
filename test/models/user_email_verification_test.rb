require "test_helper"

class UserEmailVerificationTest < ActiveSupport::TestCase
  test "email verification token is independent, expiring, and state bound" do
    user = User.create!(
      name: "Pending Verification",
      email_address: "verification-token@example.test",
      password: "password",
      password_confirmation: "password",
      role: "owner",
      active: false,
      email_verification_sent_at: Time.current
    )
    token = user.generate_token_for(:email_verification)

    assert_not_includes User.column_names, "email_verification_token"
    assert_equal user, User.find_by_token_for!(:email_verification, token)
    assert_raises(ActiveSupport::MessageVerifier::InvalidSignature) do
      User.find_by_token_for!(:invitation, token)
    end

    travel User::EMAIL_VERIFICATION_EXPIRES_IN + 1.second do
      assert_raises(ActiveSupport::MessageVerifier::InvalidSignature) do
        User.find_by_token_for!(:email_verification, token)
      end
    end

    user.update!(email_verification_sent_at: 1.second.from_now)
    assert_raises(ActiveSupport::MessageVerifier::InvalidSignature) do
      User.find_by_token_for!(:email_verification, token)
    end

    replacement_token = user.generate_token_for(:email_verification)
    user.update!(email_verified_at: Time.current)
    assert_raises(ActiveSupport::MessageVerifier::InvalidSignature) do
      User.find_by_token_for!(:email_verification, replacement_token)
    end

    user.update!(email_verified_at: nil)
    active_state_token = user.generate_token_for(:email_verification)
    user.update!(active: true)
    assert_raises(ActiveSupport::MessageVerifier::InvalidSignature) do
      User.find_by_token_for!(:email_verification, active_state_token)
    end
  end

  test "verification timestamps require a sent timestamp at model and database layers" do
    user = User.new(
      name: "Invalid Verification",
      email_address: "invalid-verification@example.test",
      password: "password",
      password_confirmation: "password",
      role: "owner",
      active: false,
      email_verified_at: Time.current
    )

    assert_not user.valid?
    assert_includes user.errors[:email_verified_at], "requires a verification email timestamp"

    assert_raises(ActiveRecord::StatementInvalid) do
      User.transaction(requires_new: true) do
        User.insert_all!([ {
          active: false,
          created_at: Time.current,
          email_address: "invalid-verification-db@example.test",
          email_verified_at: Time.current,
          name: "Invalid Verification DB",
          password_digest: BCrypt::Password.create("password"),
          role: "owner",
          updated_at: Time.current
        } ])
      end
    end
  end
end
