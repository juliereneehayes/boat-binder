class MfaEnrollmentsController < ApplicationController
  CONFIRMATION_FAILURE_MESSAGE = "We couldn't verify that code. Try again."

  allow_unauthenticated_access
  before_action :load_mfa_context

  def show
    if @user.mfa_enrolled?
      redirect_after_existing_enrollment
      return
    end

    unless @user.mfa_enrollment_pending?
      redirect_to settings_path(anchor: "security")
      return
    end

    prepare_enrollment
  end

  def create
    if @user.mfa_enrolled?
      redirect_after_existing_enrollment
      return
    end

    @user.begin_mfa_enrollment! unless @user.mfa_enrollment_pending?
    redirect_to settings_mfa_enrollment_path, status: :see_other
  end

  def update
    unless @user.mfa_enrollment_pending?
      redirect_after_existing_enrollment
      return
    end

    recovery_codes = nil
    completed = false

    User.transaction do
      recovery_codes = @user.confirm_mfa_enrollment!(enrollment_params[:code])
      next unless recovery_codes
      raise ActiveRecord::Rollback if @challenge && !Mfa::Challenge.consume!(@challenge)

      start_new_session_for(@user) if @challenge
      SecurityAudit::Recorder.record!(
        action: "authentication.mfa_enrolled",
        actor: Current.user,
        target: @user,
        request_id: request.request_id,
        source_ip: request.remote_ip
      )
      completed = true
    end

    if completed
      Mfa::Challenge.clear!(cookies) if @challenge
      @recovery_codes = recovery_codes
      @continue_url = @challenge ? after_authentication_url : settings_path(anchor: "security")
      render "mfa/recovery_codes"
    else
      prepare_enrollment
      flash.now[:alert] = CONFIRMATION_FAILURE_MESSAGE
      render :show, status: :unprocessable_entity
    end
  end

  private

  def load_mfa_context
    if authenticated?
      @user = Current.user
      return
    end

    @challenge = Mfa::Challenge.resolve(cookies:)
    @user = @challenge&.user
    return if @user

    Mfa::Challenge.clear!(cookies)
    redirect_to new_session_path, alert: Authentication::GENERIC_LOGIN_FAILURE_MESSAGE
  end

  def enrollment_params
    params.fetch(:mfa, ActionController::Parameters.new).permit(:code)
  end

  def prepare_enrollment
    provisioning_uri = @user.mfa_enrollment_provisioning_uri
    @manual_secret = @user.mfa_enrollment_secret
    @qr_svg = RQRCode::QRCode.new(provisioning_uri).as_svg(
      color: "0B1F35",
      fill: "ffffff",
      module_size: 5,
      shape_rendering: "crispEdges",
      use_path: true
    )
  end

  def redirect_after_existing_enrollment
    redirect_to @challenge ? new_mfa_challenge_path : settings_path(anchor: "security")
  end
end
