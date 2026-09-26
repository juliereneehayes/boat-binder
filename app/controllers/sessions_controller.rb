class SessionsController < ApplicationController
  EMAIL_RATE_LIMIT_KEY_PURPOSE = "sign-in-email-rate-limit"
  RATE_LIMIT_STORE = Rails.env.test? ? ActiveSupport::Cache::MemoryStore.new : Rails.cache
  THROTTLED_LOGIN_MESSAGE = "Try again later."

  allow_unauthenticated_access only: %i[ new create ]
  # Keep this before rate_limit: signed-in browsers must be redirected without
  # consuming login attempts, and credentials must never replace the current identity.
  before_action :redirect_authenticated_user, only: %i[ new create ]
  rate_limit to: 10, within: 3.minutes, only: :create, name: "ip",
    store: RATE_LIMIT_STORE,
    with: :throttled_login
  rate_limit to: 10, within: 15.minutes, only: :create, name: "email",
    by: :sign_in_email_rate_limit_key,
    store: RATE_LIMIT_STORE,
    with: :throttled_login

  def new
  end

  def create
    if user = User.authenticate_by(email_address: params[:email_address], password: params[:password])
      unless user.active?
        redirect_to new_session_path, alert: Authentication::GENERIC_LOGIN_FAILURE_MESSAGE
        return
      end

      start_new_session_for user
      redirect_to after_authentication_url
    else
      redirect_to new_session_path, alert: Authentication::GENERIC_LOGIN_FAILURE_MESSAGE
    end
  end

  def destroy
    terminate_session
    redirect_to new_session_path, status: :see_other
  end

  private

  def sign_in_email_rate_limit_key
    EmailRateLimitKey.call(params[:email_address], purpose: EMAIL_RATE_LIMIT_KEY_PURPOSE)
  end

  def throttled_login
    redirect_to new_session_path, alert: THROTTLED_LOGIN_MESSAGE
  end

  def redirect_authenticated_user
    redirect_to root_path if authenticated?
  end
end
