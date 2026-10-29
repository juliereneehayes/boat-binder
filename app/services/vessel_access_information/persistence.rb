class VesselAccessInformation
  class Persistence
    CHANGED_FIELDS = %w[restricted_details].freeze

    def self.save!(vessel:, restricted_details:, actor:, request_id: nil, source_ip: nil)
      raise ArgumentError, "actor is required" unless actor&.persisted?
      raise ArgumentError, "vessel must be a persisted Vessel" unless vessel&.persisted? && vessel.asset_type == "vessel"

      record = vessel.vessel_access_information || vessel.build_vessel_access_information
      creating = record.new_record?
      record.restricted_details = restricted_details
      return record unless record.changed?

      record.transaction do
        record.save!
        SecurityAudit::Recorder.record!(
          action: creating ? "vessel_access_information.created" : "vessel_access_information.updated",
          actor:,
          account: vessel.account,
          target: record,
          request_id:,
          source_ip:,
          changed_fields: CHANGED_FIELDS
        )
      end

      record
    end

    private_class_method :new
  end
end
