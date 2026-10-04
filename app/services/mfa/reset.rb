module Mfa
  class Reset
    def self.call!(user:, actor: nil, request_id: nil)
      User.transaction do
        user.reset_mfa_for_reenrollment!
        user.sessions.destroy_all
        SecurityAudit::Recorder.record!(
          action: "authentication.mfa_reenrollment_started",
          actor:,
          target: user,
          request_id:
        )
      end
    end
  end
end
