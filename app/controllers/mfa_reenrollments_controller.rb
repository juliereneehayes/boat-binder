class MfaReenrollmentsController < ApplicationController
  FAILURE_MESSAGE = "We couldn't start MFA re-enrollment. Check your password and try again."
  THROTTLED_MESSAGE = "Try again later."

  rate_limit to: 5, within: 15.minutes, only: :create, name: "authenticated-user",
    by: :password_rate_limit_key,
    store: Mfa::PasswordReauthenticationRateLimit::RATE_LIMIT_STORE,
    with: :throttled_reauthentication

  def create
    unless Current.user.mfa_enrolled? && Current.user.authenticate(reenrollment_params[:current_password])
      redirect_to settings_path(anchor: "security"), alert: FAILURE_MESSAGE, status: :see_other
      return
    end

    user = Current.user
    Mfa::Reset.call!(
      user:,
      actor: user,
      request_id: request.request_id
    )
    Mfa::Challenge.issue!(cookies:, user:)
    Current.session = nil
    clear_session_cookie
    redirect_to settings_mfa_enrollment_path, status: :see_other
  end

  private

  def reenrollment_params
    params.fetch(:mfa, ActionController::Parameters.new).permit(:current_password)
  end

  def password_rate_limit_key
    Mfa::PasswordReauthenticationRateLimit.key(Current.user)
  end

  def throttled_reauthentication
    redirect_to settings_path(anchor: "security"), alert: THROTTLED_MESSAGE, status: :see_other
  end
end
