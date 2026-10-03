module Mfa
  class Policy
    ENFORCEMENT_ENV = "PRIVILEGED_MFA_ENFORCEMENT"
    ENFORCEMENT_OVERRIDE_KEY = :privileged_mfa_enforcement_override

    class << self
      def required_for_sign_in?(user)
        user.mfa_enrolled? || user.mfa_enrollment_pending? || privileged_enforcement? && user.internal?
      end

      def privileged_enforcement?
        override = ActiveSupport::IsolatedExecutionState[ENFORCEMENT_OVERRIDE_KEY]
        return override unless override.nil?

        ActiveModel::Type::Boolean.new.cast(ENV.fetch(ENFORCEMENT_ENV, false))
      end

      def with_privileged_enforcement(value)
        had_previous = ActiveSupport::IsolatedExecutionState.key?(ENFORCEMENT_OVERRIDE_KEY)
        previous = ActiveSupport::IsolatedExecutionState[ENFORCEMENT_OVERRIDE_KEY]
        ActiveSupport::IsolatedExecutionState[ENFORCEMENT_OVERRIDE_KEY] = value
        yield
      ensure
        if had_previous
          ActiveSupport::IsolatedExecutionState[ENFORCEMENT_OVERRIDE_KEY] = previous
        else
          ActiveSupport::IsolatedExecutionState.delete(ENFORCEMENT_OVERRIDE_KEY)
        end
      end
    end
  end
end
