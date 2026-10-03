class MfaRecoveryCodesController < ApplicationController
  FAILURE_MESSAGE = "We couldn't regenerate recovery codes. Check your password and try again."

  def create
    unless Current.user.mfa_enrolled? && Current.user.authenticate(recovery_code_params[:current_password])
      redirect_to settings_path(anchor: "security"), alert: FAILURE_MESSAGE, status: :see_other
      return
    end

    recovery_codes = nil
    User.transaction do
      recovery_codes = Current.user.regenerate_mfa_recovery_codes!
      SecurityAudit::Recorder.record!(
        action: "authentication.mfa_recovery_codes_regenerated",
        actor: Current.user,
        target: Current.user,
        request_id: request.request_id,
        source_ip: request.remote_ip
      )
    end

    @recovery_codes = recovery_codes
    @continue_url = settings_path(anchor: "security")
    render "mfa/recovery_codes"
  end

  private

  def recovery_code_params
    params.fetch(:mfa, ActionController::Parameters.new).permit(:current_password)
  end
end
