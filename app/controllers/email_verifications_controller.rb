class EmailVerificationsController < ApplicationController
  AUTHENTICATED_VERIFICATION_MESSAGE = "Sign out before verifying another account."
  VERIFICATION_FAILURE_MESSAGE =
    "This verification link is invalid or has expired. Request a new verification email to continue."
  RESEND_NOTICE = "If the email is eligible, a new verification link will arrive shortly."
  EMAIL_RATE_LIMIT_KEY_PURPOSE = "email-verification-resend-rate-limit"
  RATE_LIMIT_STORE = Rails.env.test? ? ActiveSupport::Cache::MemoryStore.new : Rails.cache
  TOKEN_FORMAT = /\A[A-Za-z0-9_=\-]{64,1024}\z/

  class IneligibleVerification < StandardError; end

  allow_unauthenticated_access
  before_action :redirect_authenticated_user
  before_action :set_user_by_email_verification, only: :create
  rate_limit to: 5, within: 15.minutes, only: :resend, name: "ip",
    store: RATE_LIMIT_STORE,
    with: -> { redirect_to new_email_verification_path, notice: RESEND_NOTICE }
  rate_limit to: 5, within: 1.hour, only: :resend, name: "email",
    by: :resend_email_rate_limit_key,
    store: RATE_LIMIT_STORE,
    with: -> { redirect_to new_email_verification_path, notice: RESEND_NOTICE }

  def show
  end

  def create
    session_destination = nil
    User.transaction do
      @user.lock!
      @user.account_memberships.reset
      raise IneligibleVerification unless SelfServiceRegistration.pending_verification?(@user)

      @user.update!(email_verified_at: Time.current, active: true)
      @user.sessions.destroy_all
      session_destination = establish_session_after_primary_authentication(
        @user,
        session_redirect: billing_checkout_path
      )
    end

    redirect_to session_destination, notice: "Email verified. Choose your Self Managed plan."
  rescue ActiveRecord::RecordInvalid, IneligibleVerification
    verification_failed
  end

  def new
  end

  def resend
    EmailVerificationResend.new(normalized_resend_email).call
    redirect_to new_email_verification_path, notice: RESEND_NOTICE, status: :see_other
  end

  private

  def redirect_authenticated_user
    redirect_to root_path, alert: AUTHENTICATED_VERIFICATION_MESSAGE if authenticated?
  end

  def set_user_by_email_verification
    @user = User.find_by_token_for!(:email_verification, verification_token)
  rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound,
    ActionController::ParameterMissing
    verification_failed
  end

  def verification_token
    token = params.require(:token)
    raise ActiveSupport::MessageVerifier::InvalidSignature unless token.is_a?(String) && token.match?(TOKEN_FORMAT)

    token
  end

  def verification_failed
    redirect_to new_email_verification_path, alert: VERIFICATION_FAILURE_MESSAGE, status: :see_other
  end

  def normalized_resend_email
    EmailRateLimitKey.normalize(params[:email_address])
  end

  def resend_email_rate_limit_key
    EmailRateLimitKey.call(params[:email_address], purpose: EMAIL_RATE_LIMIT_KEY_PURPOSE)
  end
end
