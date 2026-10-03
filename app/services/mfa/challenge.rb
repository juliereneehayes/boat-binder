require "openssl"

module Mfa
  class Challenge
    COOKIE_NAME = :mfa_challenge
    EXPIRES_IN = 10.minutes
    RATE_LIMIT_KEY_PURPOSE = "mfa-challenge-rate-limit"
    CONSUMED_KEY_PURPOSE = "mfa-challenge-consumed"
    CREDENTIAL_KEY_PURPOSE = "mfa-challenge-credential-state"
    STORE_OVERRIDE_KEY = :mfa_challenge_store
    Claim = Data.define(:user, :nonce, :expires_at)

    class << self
      def issue!(cookies:, user:)
        expires_at = EXPIRES_IN.from_now
        cookies.encrypted[COOKIE_NAME] = {
          value: {
            user_id: user.id,
            nonce: SecureRandom.hex(16),
            credential_state: credential_state(user),
            expires_at: expires_at.to_i
          },
          expires: expires_at,
          httponly: true,
          same_site: :lax,
          secure: Rails.env.production?
        }
      end

      def resolve(cookies:)
        payload = cookies.encrypted[COOKIE_NAME]
        return unless payload.is_a?(Hash)

        user_id = payload["user_id"] || payload[:user_id]
        nonce = payload["nonce"] || payload[:nonce]
        expires_at = Time.zone.at(payload["expires_at"] || payload[:expires_at])
        supplied_state = payload["credential_state"] || payload[:credential_state]
        return if user_id.blank? || nonce.blank? || expires_at <= Time.current
        return if consumed?(nonce)

        user = User.find_by(id: user_id)
        return unless user&.active?
        return unless secure_compare(supplied_state, credential_state(user))

        Claim.new(user:, nonce:, expires_at:)
      rescue ArgumentError, TypeError
        nil
      end

      def consume!(claim)
        store.write(consumed_key(claim.nonce), true, expires_in: EXPIRES_IN, unless_exist: true)
      end

      def rate_limit_key(claim)
        private_identifier(claim&.user&.id.to_s, purpose: RATE_LIMIT_KEY_PURPOSE)
      end

      def clear!(cookies)
        cookies.delete(
          COOKIE_NAME,
          httponly: true,
          same_site: :lax,
          secure: Rails.env.production?
        )
      end

      def store
        ActiveSupport::IsolatedExecutionState[STORE_OVERRIDE_KEY] || Rails.cache
      end

      def with_store(store)
        had_previous = ActiveSupport::IsolatedExecutionState.key?(STORE_OVERRIDE_KEY)
        previous = ActiveSupport::IsolatedExecutionState[STORE_OVERRIDE_KEY]
        ActiveSupport::IsolatedExecutionState[STORE_OVERRIDE_KEY] = store
        yield
      ensure
        if had_previous
          ActiveSupport::IsolatedExecutionState[STORE_OVERRIDE_KEY] = previous
        else
          ActiveSupport::IsolatedExecutionState.delete(STORE_OVERRIDE_KEY)
        end
      end

      private

      def consumed?(nonce)
        store.exist?(consumed_key(nonce))
      end

      def consumed_key(nonce)
        "mfa-challenge:consumed:#{private_identifier(nonce, purpose: CONSUMED_KEY_PURPOSE)}"
      end

      def credential_state(user)
        state = [ user.id, user.password_digest, user.role, user.active? ].join("\0")
        private_identifier(state, purpose: CREDENTIAL_KEY_PURPOSE)
      end

      def private_identifier(value, purpose:)
        key = Rails.application.key_generator.generate_key(purpose, 32)
        OpenSSL::HMAC.hexdigest("SHA256", key, value)
      end

      def secure_compare(left, right)
        left.is_a?(String) && left.bytesize == right.bytesize &&
          ActiveSupport::SecurityUtils.secure_compare(left, right)
      end
    end
  end
end
