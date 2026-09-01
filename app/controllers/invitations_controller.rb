class InvitationsController < ApplicationController
  INVITATION_INVALID_MESSAGE = "Invitation link is invalid or has expired."

  allow_unauthenticated_access
  # Invitation acceptance starts a session, so require an explicit sign-out before
  # another identity can be activated in the current browser.
  before_action :redirect_authenticated_user
  before_action :set_user_by_invitation

  def edit
  end

  def update
    @user.assign_attributes(invitation_params.merge(active: true, invitation_accepted_at: Time.current))

    if @user.save
      @user.sessions.destroy_all
      start_new_session_for @user
      redirect_to root_path, notice: "Invitation accepted. Welcome to Boat Binder."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

    def redirect_authenticated_user
      redirect_to root_path, alert: "Sign out before accepting an invitation." if authenticated?
    end

    def set_user_by_invitation
      @token = params[:token]
      @user = User.find_by_token_for!(:invitation, @token)
    rescue ActiveSupport::MessageVerifier::InvalidSignature, ActiveRecord::RecordNotFound
      redirect_to new_session_path, alert: INVITATION_INVALID_MESSAGE
    end

    def invitation_params
      params.permit(:password, :password_confirmation)
    end
end
