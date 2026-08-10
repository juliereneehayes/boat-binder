class ServiceVisitsController < ApplicationController
  before_action :require_internal!, only: %i[new create]
  before_action :set_vessel, if: -> { params[:vessel_id].present? }
  before_action :set_service_visit, only: %i[show report]

  def index
    service_visits = if @vessel
      @vessel.service_visits.includes(*service_visit_includes).recent
    else
      scoped_service_visits.includes(*service_visit_includes).recent
    end

    @service_visits = service_visits.load
  end

  def new
    @service_visit = @vessel.service_visits.new(
      visit_date: account_today(@vessel.account),
      performed_by_user: Current.user,
      location: default_location
    )
    @service_visit.build_workflow_defaults
  end

  def create
    @service_visit = @vessel.service_visits.new(service_visit_params)
    @service_visit.performed_by_user = Current.user
    @service_visit.build_workflow_defaults
    assign_engine_readings
    assign_inspection_checks
    assign_battery_checks

    if @service_visit.save
      create_issue_note if issue_note_present?
      deliver_summary_email
      redirect_to vessel_service_visit_path(@vessel, @service_visit), notice: "Visit report saved."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def show
  end

  def report
  end

  private

  def set_service_visit
    @service_visit = @vessel.service_visits.includes(
      :performed_by_user,
      :service_visit_inspection_checks,
      service_visit_engine_readings: :asset_engine,
      service_visit_battery_checks: :asset_battery,
      photos_attachments: :blob
    ).find(params[:id])
    @issue_notes = @vessel.binder_notes.where(note_type: "issue").order(created_at: :desc).limit(3)
  end

  def service_visit_includes
    [
      :performed_by_user,
      :service_visit_inspection_checks,
      asset: :account,
      service_visit_engine_readings: :asset_engine
    ]
  end

  def set_vessel
    @vessel = scoped_vessels.find_by!(slug: params[:vessel_id])
  end

  def service_visit_params
    params.require(:service_visit).permit(
      :visit_date,
      :engine_hours,
      :location,
      :summary,
      :condition_notes,
      :follow_up_needed,
      :follow_up_notes,
      photos: []
    )
  end

  def assign_engine_readings
    submitted_readings = params.dig(:service_visit, :engine_readings) || {}

    @service_visit.service_visit_engine_readings.each do |reading|
      attrs = submitted_readings[reading.asset_engine_id.to_s] || {}
      reading.hours = attrs[:hours]
    end
  end

  def assign_inspection_checks
    submitted_checks = params.dig(:service_visit, :inspection_checks) || {}

    @service_visit.ordered_inspection_checks.each_with_index do |check, index|
      attrs = submitted_checks[index.to_s] || {}
      check.checked = ActiveModel::Type::Boolean.new.cast(attrs.fetch(:checked, "0"))
      check.notes = attrs[:notes]
    end
  end

  def assign_battery_checks
    submitted_checks = params.dig(:service_visit, :battery_checks) || {}

    @service_visit.service_visit_battery_checks.each do |check|
      attrs = submitted_checks[check.asset_battery_id.to_s] || {}
      check.checked = ActiveModel::Type::Boolean.new.cast(attrs.fetch(:checked, "0"))
      check.voltage = attrs[:voltage]
      check.notes = attrs[:notes]
    end
  end

  def issue_note_present?
    params[:issue_title].present? || params[:issue_body].present?
  end

  def create_issue_note
    @vessel.binder_notes.create!(
      account: @vessel.account,
      title: params[:issue_title].presence || "Issue from #{@service_visit.visit_date.to_fs(:long)}",
      body: params[:issue_body].presence || "Issue noted during vessel visit.",
      note_type: "issue"
    )
  end

  def deliver_summary_email
    recipient_email = @service_visit.summary_recipient_email
    unless recipient_email
      Rails.logger.info("Service visit summary email skipped for service_visit_id=#{@service_visit.id}: no recipient")
      return false
    end

    ServiceVisitMailer.summary(@service_visit, recipient_email).deliver_now
    Rails.logger.info("Service visit summary email delivered for service_visit_id=#{@service_visit.id}")
    true
  rescue *ApplicationMailer::DELIVERY_ERRORS => error
    Rails.logger.error(
      "Service visit summary email delivery failed for service_visit_id=#{@service_visit.id}: #{error.class}: #{error.message}"
    )
    false
  end

  def default_location
    [ @vessel.marina, @vessel.slip.presence && "Slip #{@vessel.slip}" ].compact.join(", ")
  end
end
