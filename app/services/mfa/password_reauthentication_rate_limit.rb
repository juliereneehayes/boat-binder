module Mfa
  class PasswordReauthenticationRateLimit
    KEY_PURPOSE = "mfa-sensitive-action-authenticated-user-rate-limit"
    STORE_OVERRIDE_KEY = :mfa_password_reauthentication_rate_limit_store

    class Store
      def increment(...)
        PasswordReauthenticationRateLimit.store.increment(...)
      end
    end

    RATE_LIMIT_STORE = Store.new

    class << self
      def key(user)
        EmailRateLimitKey.call(user.id.to_s, purpose: KEY_PURPOSE)
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
    end
  end
end
