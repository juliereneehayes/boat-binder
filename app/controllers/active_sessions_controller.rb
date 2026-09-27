class ActiveSessionsController < ApplicationController
  def show
    @active_sessions = Current.user.sessions.includes(:user).order(created_at: :desc).select(&:valid_at?)
  end

  def destroy_others
    Current.user.sessions.where.not(id: Current.session.id).destroy_all
    redirect_to active_sessions_path, notice: "Other sessions signed out.", status: :see_other
  end
end
