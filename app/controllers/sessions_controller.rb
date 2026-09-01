class SessionsController < ApplicationController
  allow_unauthenticated_access only: %i[ new create ]
  # Keep this before rate_limit: signed-in browsers must be redirected without
  # consuming login attempts, and credentials must never replace the current identity.
  before_action :redirect_authenticated_user, only: %i[ new create ]
  rate_limit to: 10, within: 3.minutes, only: :create, with: -> { redirect_to new_session_path, alert: "Try again later." }

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

  def redirect_authenticated_user
    redirect_to root_path if authenticated?
  end
end
