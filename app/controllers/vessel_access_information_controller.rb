class VesselAccessInformationController < ApplicationController
  include NoStoreResponse

  before_action :set_vessel

  def update
    VesselAccessInformation::Persistence.update_fields!(
      vessel: @vessel,
      updates: restricted_field_updates,
      actor: current_user,
      request_id: request.request_id
    )

    redirect_to vessel_path(@vessel, anchor: "access-operations"),
      notice: "Restricted access information updated.",
      status: :see_other
  rescue ActiveRecord::RecordInvalid => error
    redirect_to vessel_path(@vessel, anchor: "access-operations"),
      alert: "Restricted access information was not saved. #{error.record.errors.full_messages.to_sentence}",
      status: :see_other
  rescue VesselAccessInformation::Persistence::InvalidUpdate => error
    redirect_to vessel_path(@vessel, anchor: "access-operations"),
      alert: "Restricted access information was not saved. #{error.message}",
      status: :see_other
  rescue Authorization::RestrictedVesselPolicy::AccessDenied
    deny_access!
  end

  def reveal
    value = VesselAccessInformation::Revealer.reveal!(
      vessel: @vessel,
      field: restricted_field,
      actor: current_user,
      request_id: request.request_id
    )

    if value.present?
      render partial: "vessels/revealed_restricted_field",
        locals: { vessel: @vessel, field: restricted_field, value: }
    else
      render_restricted_field_state(present: false)
    end
  rescue Authorization::RestrictedVesselPolicy::AccessDenied
    deny_access!
  end

  def hide
    Authorization::RestrictedVesselPolicy.new(user: current_user).authorize_read!(@vessel)
    render_restricted_field_state(present: true)
  rescue Authorization::RestrictedVesselPolicy::AccessDenied
    deny_access!
  end

  private

  def set_vessel
    @vessel = scoped_vessels.includes(:account).find_by!(slug: params[:vessel_id])
  end

  def restricted_field
    @restricted_field ||= params.require(:field).to_s.tap do |field|
      raise ActiveRecord::RecordNotFound unless VesselAccessInformation::RESTRICTED_FIELD_NAMES.include?(field)
    end
  end

  def restricted_field_updates
    permitted_fields = VesselAccessInformation::RESTRICTED_FIELD_NAMES.index_with do
      [ :operation, :value ]
    end
    params.fetch(:restricted_fields, ActionController::Parameters.new).permit(permitted_fields).to_h
  end

  def render_restricted_field_state(present:)
    render partial: "vessels/restricted_field_state",
      locals: { vessel: @vessel, field: restricted_field, present: }
  end
end
