class EmailChangeConfirmationsController < ApplicationController
  FAILURE_MESSAGE = "This email change link is invalid or has expired. Sign in to request a new one."
  TOKEN_FORMAT = /\A[A-Za-z0-9_=\-]{64,1024}\z/

  class IneligibleEmailChange < StandardError; end

  allow_unauthenticated_access

  def show
  end

  def create
    token = confirmation_token
    user = User.find_by_token_for!(:email_change, token)

    User.transaction do
      user.lock!
      locked_user = User.find_by_token_for!(:email_change, token)
      raise IneligibleEmailChange unless locked_user == user && user.active? && user.email_change_pending?

      user.update!(
        email_address: user.pending_email_address,
        pending_email_address: nil,
        email_change_requested_at: nil
      )
      user.sessions.destroy_all
    end

    Current.session = nil
    clear_session_cookie
    redirect_to new_session_path, notice: "Email changed. Sign in with your new email address."
  rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound,
    ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, IneligibleEmailChange,
    ActionController::ParameterMissing
    redirect_to new_session_path, alert: FAILURE_MESSAGE, status: :see_other
  end

  private

  def confirmation_token
    token = params.require(:token)
    raise ActiveSupport::MessageVerifier::InvalidSignature unless token.is_a?(String) && token.match?(TOKEN_FORMAT)

    token
  end
end
