class SettingsController < ApplicationController
  before_action :load_active_sessions, only: %i[show update]

  def show
    @user = Current.user
  end

  def update
    @user = Current.user

    if @user.update(settings_params)
      redirect_to settings_path, notice: "Name updated."
    else
      render :show, status: :unprocessable_entity
    end
  end

  def destroy_other_sessions
    Current.user.sessions.where.not(id: Current.session.id).destroy_all
    redirect_to settings_path(anchor: "security"), notice: "Other sessions signed out.", status: :see_other
  end

  private

  def load_active_sessions
    @active_sessions = Current.user.active_sessions
  end

  def settings_params
    params.require(:user).permit(:name)
  end
end
