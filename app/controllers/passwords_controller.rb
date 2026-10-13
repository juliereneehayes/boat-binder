class PasswordsController < ApplicationController
  RESET_REQUEST_NOTICE = "If an account exists for that email, reset instructions will be sent shortly."
  AUTHENTICATED_RESET_MESSAGE = "Sign out before resetting a password."
  EMAIL_RATE_LIMIT_KEY_PURPOSE = "password-reset-email-rate-limit"
  RATE_LIMIT_STORE_OVERRIDE_KEY = :passwords_controller_rate_limit_store

  class RateLimitStore
    def increment(...)
      PasswordsController.rate_limit_store.increment(...)
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

  allow_unauthenticated_access
  # Password reset changes credentials, so require explicit sign-out before
  # validating a token or rendering the form for another browser identity.
  before_action :redirect_authenticated_user, only: %i[ edit update ]
  before_action :set_user_by_token, only: %i[ edit update ]
  rate_limit to: 10, within: 3.minutes, only: :create, name: "ip",
    store: RATE_LIMIT_STORE,
    with: :reset_request_response
  # Five recovery messages per hour allows normal retries while bounding targeted abuse.
  rate_limit to: 5, within: 1.hour, only: :create, name: "email",
    by: :password_reset_email_rate_limit_key,
    store: RATE_LIMIT_STORE,
    with: :reset_request_response

  def new
  end

  def create
    user = User.find_by(email_address: EmailRateLimitKey.normalize(params[:email_address]))
    enqueue_password_reset(user&.id)

    reset_request_response
  end

  def edit
  end

  def update
    if @user.update(params.permit(:password, :password_confirmation))
      @user.sessions.destroy_all
      redirect_to new_session_path, notice: "Password has been reset."
    else
      redirect_to edit_password_path(params[:token]), alert: password_reset_error_message
    end
  end

  private
    def password_reset_error_message
      %i[password password_confirmation]
        .flat_map { |attribute| @user.errors.full_messages_for(attribute) }
        .to_sentence
        .presence || "Password could not be reset."
    end

    def redirect_authenticated_user
      redirect_to root_path, alert: AUTHENTICATED_RESET_MESSAGE if authenticated?
    end

    def enqueue_password_reset(user_id)
      PasswordResetDeliveryJob.perform_later(user_id)
      Rails.logger.info("Password reset delivery queued for user_id=#{user_id}")
    rescue StandardError => error
      Rails.logger.error(
        "Password reset delivery enqueue failed for user_id=#{user_id} " \
        "exception_class=#{error.class.name}"
      )
    end

    def password_reset_email_rate_limit_key
      EmailRateLimitKey.call(params[:email_address], purpose: EMAIL_RATE_LIMIT_KEY_PURPOSE)
    end

    def reset_request_response
      redirect_to new_session_path, notice: RESET_REQUEST_NOTICE
    end

    def set_user_by_token
      @user = User.find_by_password_reset_token!(params[:token])
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      redirect_to new_password_path, alert: "Password reset link is invalid or has expired."
    end
end
