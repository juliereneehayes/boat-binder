class VesselAccessInformation
  class Revealer
    def self.reveal!(vessel:, field:, actor:, request_id: nil)
      field = field.to_s
      raise ActiveRecord::RecordNotFound unless RESTRICTED_FIELD_NAMES.include?(field)

      canonical_vessel = canonical_vessel(vessel)
      account = canonical_vessel&.account
      raise Authorization::RestrictedVesselPolicy::AccessDenied,
        Authorization::ACCESS_DENIED_MESSAGE unless account&.persisted?

      canonical_vessel.with_lock do
        account = canonical_vessel.account

        account.with_lock do
          authorized_vessel = Authorization::RestrictedVesselPolicy.new(user: actor).authorize_read!(canonical_vessel)
          record = VesselAccessInformation.find_by(asset_id: authorized_vessel.id)
          value = record&.restricted_field(field)
          return if value.blank?

          SecurityAudit::Recorder.record!(
            action: "vessel_access_information.revealed",
            actor:,
            account:,
            target: record,
            request_id:,
            changed_fields: [ field ]
          )
          value
        end
      end
    rescue Authorization::RestrictedVesselPolicy::AccessDenied
      record_denial(actor:, vessel:, field:, request_id:)
      raise
    end

    def self.record_denial(actor:, vessel:, field:, request_id:)
      audited_vessel = canonical_asset(vessel)
      return unless audited_vessel&.account&.persisted?

      changed_fields = RESTRICTED_FIELD_NAMES.include?(field.to_s) ? [ field.to_s ] : []
      SecurityAudit::Recorder.record!(
        action: "vessel_access_information.reveal_denied",
        outcome: "denied",
        actor: actor&.persisted? ? actor : nil,
        account: audited_vessel.account,
        target: audited_vessel,
        request_id:,
        changed_fields:
      )
    rescue StandardError => error
      Rails.logger.error("Vessel access information reveal denial audit failed: #{error.class}")
    end
    private_class_method :record_denial

    def self.canonical_vessel(vessel)
      return unless vessel.respond_to?(:persisted?) && vessel.persisted?

      Asset.vessels.includes(:account).find_by(id: vessel.id)
    end
    private_class_method :canonical_vessel

    def self.canonical_asset(vessel)
      return unless vessel.respond_to?(:persisted?) && vessel.persisted?

      Asset.includes(:account).find_by(id: vessel.id)
    end
    private_class_method :canonical_asset

    private_class_method :new
  end
end
