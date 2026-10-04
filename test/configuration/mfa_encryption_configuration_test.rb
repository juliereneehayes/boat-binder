require "test_helper"

class MfaEncryptionConfigurationTest < ActiveSupport::TestCase
  test "production requires dedicated current key and derivation salt" do
    error = assert_raises(KeyError) do
      MfaEncryptionConfiguration.build(environment: "production", env: {})
    end

    assert_includes error.message, MfaEncryptionConfiguration::PRIMARY_KEY_ENV
    assert_includes error.message, MfaEncryptionConfiguration::KEY_DERIVATION_SALT_ENV
  end

  test "production configures previous keys for decryption and current key for encryption" do
    old_key = SecureRandom.hex(32)
    current_key = SecureRandom.hex(32)
    salt = SecureRandom.hex(32)
    configuration = MfaEncryptionConfiguration.build(
      environment: "production",
      env: {
        MfaEncryptionConfiguration::PRIMARY_KEY_ENV => current_key,
        MfaEncryptionConfiguration::PREVIOUS_PRIMARY_KEYS_ENV => old_key,
        MfaEncryptionConfiguration::KEY_DERIVATION_SALT_ENV => salt
      }
    )

    assert_equal [ old_key, current_key ], configuration.primary_keys
    assert_equal salt, configuration.key_derivation_salt
  end

  test "Rails multi-key provider decrypts old ciphertext and supports re-encryption with the new key" do
    old_key = SecureRandom.hex(32)
    new_key = SecureRandom.hex(32)
    old_provider = ActiveRecord::Encryption::DerivedSecretKeyProvider.new(old_key)
    rotation_provider = ActiveRecord::Encryption::DerivedSecretKeyProvider.new([ old_key, new_key ])
    new_provider = ActiveRecord::Encryption::DerivedSecretKeyProvider.new(new_key)
    user = create_user(email: "mfa-key-rotation@example.test", role: "owner")
    secret = ROTP::Base32.random_base32(32)

    with_key_provider(old_provider) { user.update!(mfa_totp_secret: secret) }
    old_ciphertext = user.reload.ciphertext_for(:mfa_totp_secret)

    with_key_provider(rotation_provider) do
      rotating_user = User.find(user.id)
      assert_equal secret, rotating_user.mfa_totp_secret
      rotating_user.update_columns(mfa_totp_secret: rotating_user.mfa_totp_secret)
    end
    new_ciphertext = user.reload.ciphertext_for(:mfa_totp_secret)

    assert_not_equal old_ciphertext, new_ciphertext
    with_key_provider(new_provider) do
      assert_equal secret, User.find(user.id).mfa_totp_secret
    end
    assert_raises(ActiveRecord::Encryption::Errors::Decryption) do
      with_key_provider(old_provider) { User.find(user.id).mfa_totp_secret }
    end
  end

  private

  def with_key_provider(key_provider, &)
    ActiveRecord::Encryption.with_encryption_context({ key_provider: }, &)
  end
end
