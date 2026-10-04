require "test_helper"

class Mfa::PasswordReauthenticationRateLimitTest < ActiveSupport::TestCase
  test "uses a fixed-length private identifier instead of the User ID" do
    user = create_user(email: "mfa-password-rate-key@example.test", role: "owner")

    key = Mfa::PasswordReauthenticationRateLimit.key(user)

    assert_match(/\A[0-9a-f]{64}\z/, key)
    assert_not_equal user.id.to_s, key
    assert_equal key, Mfa::PasswordReauthenticationRateLimit.key(user)
  end
end
