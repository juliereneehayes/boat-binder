class RemindersController < ApplicationController
  before_action :require_write_access!, except: %i[index]
  before_action :set_reminder, only: %i[edit update]
  before_action :require_reminder_write_access!, only: %i[edit update]
  before_action :set_form_collections, only: %i[new create edit update]

  def index
    @reminders = scoped_reminders.includes(asset: :account).order(status: :desc, due_date: :asc)
  end

  def new
    @reminder = Reminder.new(due_date: Date.current, status: "pending", reminder_type: "maintenance")
  end

  def create
    @reminder = Reminder.new(reminder_params)
    assign_reminder_asset(@reminder)
    @reminder.status = "pending" if @reminder.status.blank?

    if @reminder.save
      redirect_to reminders_path, notice: "Reminder added."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if params[:status_action] == "complete"
      @reminder.complete!
      redirect_back fallback_location: reminders_path, notice: "Reminder completed."
    elsif params[:status_action] == "reopen"
      @reminder.reopen!
      redirect_back fallback_location: reminders_path, notice: "Reminder reopened."
    else
      assign_reminder_asset(@reminder)
      if @reminder.update(reminder_params)
        redirect_to reminders_path, notice: "Reminder updated."
      else
        render :edit, status: :unprocessable_entity
      end
    end
  end

  private

  def set_reminder
    @reminder = scoped_reminders.find(params[:id])
  end

  def set_form_collections
    @accounts = manageable_accounts.active.includes(:assets).ordered
    @vessels = manageable_vessels.active.includes(:account).ordered
  end

  def reminder_params
    params.require(:reminder).permit(:title, :due_date, :reminder_type, :status)
  end

  def assign_reminder_asset(reminder)
    asset_id = params.require(:reminder)[:asset_id]
    reminder.asset = manageable_vessels.find(asset_id) if asset_id.present?
  end

  def require_reminder_write_access!
    require_write_access!(@reminder.asset.account)
  end
end
