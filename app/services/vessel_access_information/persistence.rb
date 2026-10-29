class VesselAccessInformation
  class Persistence
    CHANGED_FIELDS = %w[restricted_details].freeze

    def self.save!(vessel:, restricted_details:, actor:, request_id: nil)
      canonical_vessel = canonical_vessel(vessel)
      account = canonical_vessel&.account
      raise Authorization::RestrictedVesselPolicy::AccessDenied,
        Authorization::ACCESS_DENIED_MESSAGE unless account&.persisted?

      account.with_lock do
        authorized_vessel = Authorization::RestrictedVesselPolicy.new(user: actor).authorize_write!(canonical_vessel)

        authorized_vessel.with_lock do
          record = VesselAccessInformation.find_or_initialize_by(asset_id: authorized_vessel.id)
          creating = record.new_record?
          record.restricted_details = restricted_details
          unless record.persisted? && !record.changed?
            record.save!
            SecurityAudit::Recorder.record!(
              action: creating ? "vessel_access_information.created" : "vessel_access_information.updated",
              actor:,
              account: authorized_vessel.account,
              target: record,
              request_id:,
              changed_fields: CHANGED_FIELDS
            )
          end
          record
        end
      end
    rescue Authorization::RestrictedVesselPolicy::AccessDenied
      record_denial(actor:, vessel:, request_id:)
      raise
    end

    def self.record_denial(actor:, vessel:, request_id:)
      audited_vessel = canonical_asset(vessel)
      return unless audited_vessel&.account&.persisted?

      SecurityAudit::Recorder.record!(
        action: "vessel_access_information.write_denied",
        outcome: "denied",
        actor: actor&.persisted? ? actor : nil,
        account: audited_vessel.account,
        target: audited_vessel,
        request_id:
      )
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
