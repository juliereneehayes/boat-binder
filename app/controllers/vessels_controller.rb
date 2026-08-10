class VesselsController < ApplicationController
  PrimaryPhotoAttachmentError = Class.new(StandardError)

  before_action :require_internal!, only: %i[new create destroy]
  before_action :set_vessel, only: %i[show edit update destroy destroy_primary_photo]
  before_action :require_vessel_write_access!, only: %i[edit update destroy_primary_photo]

  def index
    @query = params[:q].to_s.strip
    @include_inactive = params[:include_inactive].present?
    @vessels = scoped_vessels.search(@query).includes(:account, :reminders, :service_visits, :documents, :binder_notes).with_attached_primary_photo.ordered
    @vessels = @vessels.active unless @include_inactive
  end

  def show
    @service_visits = @vessel.service_visits.includes(
      :performed_by_user,
      :service_visit_inspection_checks,
      service_visit_engine_readings: :asset_engine,
      service_visit_battery_checks: :asset_battery
    ).recent.limit(5)
    @documents = @vessel.documents.with_attached_file.order(created_at: :desc).limit(6)
    @binder_notes = @vessel.binder_notes.order(created_at: :desc).limit(6)
    @overdue_reminders = @vessel.overdue_reminders.limit(4)
    @upcoming_reminders = @vessel.reminders.upcoming.limit(5)
    @completed_reminders = @vessel.reminders.completed.order(updated_at: :desc).limit(3)
    @open_follow_ups = @vessel.open_follow_up_visits.limit(3)
    @asset_batteries = @vessel.asset_batteries.ordered
    @owner_contact = @vessel.owner_contact
    @primary_contact = @vessel.primary_contact
    @last_visit = @vessel.last_visit
    @next_reminder = @vessel.next_reminder
    @binder_note = @vessel.binder_notes.new(account: @vessel.account)
  end

  def new
    @vessel = Asset.new(asset_type: "vessel")
    @accounts = manageable_accounts.active.ordered
  end

  def create
    primary_photo_upload = vessel_params[:primary_photo]
    @vessel = Asset.new(vessel_params.except(:primary_photo))
    @vessel.asset_type = "vessel"
    return unless assign_vessel_account(@vessel)

    if (primary_photo_error = Asset.primary_photo_upload_error(primary_photo_upload))
      render_vessel_form_with_primary_photo_error(@vessel, primary_photo_error, :new)
      return
    end

    ActiveRecord::Base.transaction do
      @vessel.save!
      attach_primary_photo!(@vessel, primary_photo_upload) if primary_photo_upload.present?
    end

    redirect_to vessel_path(@vessel), notice: "Vessel added."
  rescue ActiveRecord::RecordInvalid
    @accounts = manageable_accounts.active.ordered
    render :new, status: :unprocessable_entity
  rescue PrimaryPhotoAttachmentError => error
    Rails.logger.error("Primary photo attachment failed for vessel create: #{error.message}")
    render_vessel_form_with_primary_photo_error(@vessel, "could not be attached. Please try again.", :new)
  end

  def edit
    @accounts = owner_options_for(@vessel)
  end

  def update
    primary_photo_upload = vessel_params[:primary_photo]
    permitted_attributes = vessel_params.except(:primary_photo)
    return unless assign_vessel_account(@vessel)

    if (primary_photo_error = Asset.primary_photo_upload_error(primary_photo_upload))
      @vessel.assign_attributes(permitted_attributes)
      render_vessel_form_with_primary_photo_error(@vessel, primary_photo_error, :edit)
      return
    end

    ActiveRecord::Base.transaction do
      @vessel.update!(permitted_attributes)
      attach_primary_photo!(@vessel, primary_photo_upload) if primary_photo_upload.present?
    end

    redirect_to vessel_path(@vessel), notice: "Vessel updated."
  rescue ActiveRecord::RecordInvalid
    @accounts = owner_options_for(@vessel)
    render :edit, status: :unprocessable_entity
  rescue PrimaryPhotoAttachmentError => error
    Rails.logger.error("Primary photo attachment failed for vessel update: #{error.message}")
    render_vessel_form_with_primary_photo_error(@vessel, "could not be attached. Please try again.", :edit)
  end

  def destroy
    @vessel.destroy!
    redirect_to vessels_path, notice: "Vessel removed."
  end

  def destroy_primary_photo
    @vessel.primary_photo.purge if @vessel.primary_photo.attached?
    redirect_to vessel_path(@vessel), notice: "Primary vessel photo removed."
  end

  private

  def attach_primary_photo!(vessel, upload)
    vessel.primary_photo.attach(upload)
    raise PrimaryPhotoAttachmentError, "primary photo was not attached" unless vessel.primary_photo.attached?
  rescue StandardError => error
    raise if error.is_a?(PrimaryPhotoAttachmentError)

    raise PrimaryPhotoAttachmentError, "#{error.class}: #{error.message}"
  end

  def set_vessel
    @vessel = scoped_vessels.includes({ account: :contacts }, primary_photo_attachment: :blob).find_by!(slug: params[:id])
  end

  def vessel_params
    params.require(:asset).permit(
      :name,
      :make,
      :model,
      :year,
      :length,
      :registration_number,
      :marina,
      :slip,
      :notes,
      :active,
      :primary_photo
    )
  end

  def owner_options_for(vessel)
    manageable_accounts.where(active: true).or(manageable_accounts.where(id: vessel.account_id)).ordered
  end

  def render_vessel_form_with_primary_photo_error(vessel, message, template)
    vessel.valid?
    vessel.errors.add(:primary_photo, message)
    @accounts = template == :new ? manageable_accounts.active.ordered : owner_options_for(vessel)
    render template, status: :unprocessable_entity
  end

  def assign_vessel_account(vessel)
    return true if vessel_account_id.blank?
    return true unless internal_user?

    vessel.account = manageable_accounts.find(vessel_account_id)
    true
  end

  def vessel_account_id
    params.require(:asset)[:account_id]
  end

  def require_vessel_write_access!
    require_write_access!(@vessel.account)
  end
end
