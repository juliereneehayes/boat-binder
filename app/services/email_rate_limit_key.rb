require "openssl"

class EmailRateLimitKey
  DERIVED_KEY_LENGTH = 32

  def self.call(email_address, purpose:)
    # Purpose-specific derivation prevents identifiers from being correlated
    # across sign-in, registration, and verification-resend throttles.
    key = Rails.application.key_generator.generate_key(purpose, DERIVED_KEY_LENGTH)
    OpenSSL::HMAC.hexdigest("SHA256", key, normalize(email_address))
  end

  def self.normalize(email_address)
    email_address.is_a?(String) ? email_address.strip.downcase : ""
  end
end
