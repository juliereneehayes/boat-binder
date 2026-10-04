module Mfa
  class EnforcementActivation
    Result = Data.define(:user_count, :session_count)

    class << self
      def revoke_unenrolled_privileged_sessions!
        result = nil

        User.transaction do
          user_ids = unenrolled_privileged_users.lock.order(:id).pluck(:id)
          sessions = Session.where(user_id: user_ids)
          result = Result.new(user_count: user_ids.length, session_count: sessions.count)
          sessions.destroy_all
        end

        result
      end

      def remaining_session_count
        Session.joins(:user).where(users: { role: %w[admin captain], mfa_enrolled_at: nil }).count
      end

      private

      def unenrolled_privileged_users
        User.where(role: %w[admin captain], mfa_enrolled_at: nil)
      end
    end
  end
end
