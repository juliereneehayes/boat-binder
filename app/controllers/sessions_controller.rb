class SessionsController < ApplicationController
  EMAIL_RATE_LIMIT_KEY_PURPOSE = "sign-in-email-rate-limit"
  RATE_LIMIT_STORE_OVERRIDE_KEY = :sessions_controller_rate_limit_store
  THROTTLED_LOGIN_MESSAGE = "Try again later."

  # Resolve the backing cache per execution so focused tests can inject an
  # isolated store while all normal requests continue to use Rails.cache.
  class RateLimitStore
    def increment(...)
      SessionsController.rate_limit_store.increment(...)
    end
  end

  private_constant :RATE_LIMIT_STORE_OVERRIDE_KEY, :RateLimitStore
  RATE_LIMIT_STORE = RateLimitStore.new

  class << self
    def rate_limit_store
      ActiveSupport::IsolatedExecutionState[RATE_LIMIT_STORE_OVERRIDE_KEY] || Rails.cache
    end

    def with_rate_limit_store(store)
      had_previous_store = ActiveSupport::IsolatedExecutionState.key?(RATE_LIMIT_STORE_OVERRIDE_KEY)
      previous_store = ActiveSupport::IsolatedExecutionState[RATE_LIMIT_STORE_OVERRIDE_KEY]
      ActiveSupport::IsolatedExecutionState[RATE_LIMIT_STORE_OVERRIDE_KEY] = store
      yield
    ensure
      if had_previous_store
        ActiveSupport::IsolatedExecutionState[RATE_LIMIT_STORE_OVERRIDE_KEY] = previous_store
      else
        ActiveSupport::IsolatedExecutionState.delete(RATE_LIMIT_STORE_OVERRIDE_KEY)
      end
    end
  end

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

      if Mfa::Policy.required_for_sign_in?(user)
        user.begin_mfa_enrollment! unless user.mfa_enrolled? || user.mfa_enrollment_pending?
        Mfa::Challenge.issue!(cookies:, user:)
        redirect_to user.mfa_enrolled? ? new_mfa_challenge_path : settings_mfa_enrollment_path
      else
        start_new_session_for user
        redirect_to after_authentication_url
      end
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
