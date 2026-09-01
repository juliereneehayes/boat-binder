class PasswordsController < ApplicationController
  RESET_REQUEST_NOTICE = "If an account exists for that email, reset instructions will be sent shortly."
  AUTHENTICATED_RESET_MESSAGE = "Sign out before resetting a password."

  allow_unauthenticated_access
  # Password reset changes credentials, so require explicit sign-out before
  # validating a token or rendering the form for another browser identity.
  before_action :redirect_authenticated_user, only: %i[ edit update ]
  before_action :set_user_by_token, only: %i[ edit update ]
  rate_limit to: 10, within: 3.minutes, only: :create, with: -> { redirect_to new_password_path, alert: "Try again later." }

  def new
  end

  def create
    if user = User.find_by(email_address: params[:email_address])
      deliver_password_reset(user)
    end

    redirect_to new_session_path, notice: RESET_REQUEST_NOTICE
  end

  def edit
  end

  def update
    if @user.update(params.permit(:password, :password_confirmation))
      @user.sessions.destroy_all
      redirect_to new_session_path, notice: "Password has been reset."
    else
      redirect_to edit_password_path(params[:token]), alert: "Passwords did not match."
    end
  end

  private
    def redirect_authenticated_user
      redirect_to root_path, alert: AUTHENTICATED_RESET_MESSAGE if authenticated?
    end

    def deliver_password_reset(user)
      PasswordsMailer.reset(user).deliver_now
      Rails.logger.info("Password reset email delivered for user_id=#{user.id}")
    rescue *ApplicationMailer::DELIVERY_ERRORS => error
      Rails.logger.error(
        "Password reset email delivery failed for user_id=#{user.id}: #{error.class}: #{error.message}"
      )
    end

    def set_user_by_token
      @user = User.find_by_password_reset_token!(params[:token])
    rescue ActiveSupport::MessageVerifier::InvalidSignature
      redirect_to new_password_path, alert: "Password reset link is invalid or has expired."
    end
end
