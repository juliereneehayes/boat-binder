class MfaChallengesController < ApplicationController
  VERIFICATION_FAILURE_MESSAGE = "We couldn't verify that code. Try again."
  THROTTLED_MESSAGE = "Try again later."
  class RateLimitStore
    def increment(...)
      Mfa::Challenge.store.increment(...)
    end
  end

  private_constant :RateLimitStore
  RATE_LIMIT_STORE = RateLimitStore.new

  allow_unauthenticated_access
  before_action :redirect_authenticated_user, only: %i[new create]
  before_action :load_challenge, only: %i[new create]
  rate_limit to: 5, within: 10.minutes, only: :create, name: "challenge",
    by: :challenge_rate_limit_key,
    store: RATE_LIMIT_STORE,
    with: :throttled_verification
  rate_limit to: 20, within: 10.minutes, only: :create, name: "ip",
    store: RATE_LIMIT_STORE,
    with: :throttled_verification

  def new
    redirect_to settings_mfa_enrollment_path unless @user.mfa_enrolled?
  end

  def create
    unless @user.mfa_enrolled?
      redirect_to settings_mfa_enrollment_path
      return
    end

    factor = submitted_recovery_code? ? :recovery_code : :totp
    completed = false

    User.transaction do
      verified = if factor == :recovery_code
        @user.consume_mfa_recovery_code!(challenge_params[:recovery_code])
      else
        @user.accept_mfa_totp!(challenge_params[:code])
      end
      next unless verified
      raise ActiveRecord::Rollback unless Mfa::Challenge.consume!(@challenge)

      start_new_session_for(@user)
      record_recovery_code_use! if factor == :recovery_code
      completed = true
    end

    if completed
      Mfa::Challenge.clear!(cookies)
      redirect_to after_authentication_url
    else
      redirect_to new_mfa_challenge_path, alert: VERIFICATION_FAILURE_MESSAGE
    end
  end

  def destroy
    Mfa::Challenge.clear!(cookies)
    redirect_to new_session_path, status: :see_other
  end

  private

  def load_challenge
    @challenge = Mfa::Challenge.resolve(cookies:)
    @user = @challenge&.user
    return if @user

    Mfa::Challenge.clear!(cookies)
    redirect_to new_session_path, alert: Authentication::GENERIC_LOGIN_FAILURE_MESSAGE
  end

  def challenge_params
    params.fetch(:mfa, ActionController::Parameters.new).permit(:code, :recovery_code)
  end

  def submitted_recovery_code?
    challenge_params[:recovery_code].present?
  end

  def challenge_rate_limit_key
    Mfa::Challenge.rate_limit_key(@challenge)
  end

  def throttled_verification
    redirect_to new_mfa_challenge_path, alert: THROTTLED_MESSAGE
  end

  def redirect_authenticated_user
    redirect_to root_path if authenticated?
  end

  def record_recovery_code_use!
    SecurityAudit::Recorder.record!(
      action: "authentication.mfa_recovery_code_used",
      actor: Current.user,
      target: @user,
      request_id: request.request_id,
      source_ip: request.remote_ip
    )
  end
end
