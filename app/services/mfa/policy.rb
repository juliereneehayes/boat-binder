module Mfa
  class Policy
    class << self
      def required_for_sign_in?(user)
        user.mfa_enrolled? ||
          user.mfa_reenrollment_pending? ||
          (user.owner? && user.mfa_enrollment_pending?) ||
          user.internal?
      end
    end
  end
end
