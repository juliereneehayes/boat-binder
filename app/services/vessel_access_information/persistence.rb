class VesselAccessInformation
  class Persistence
    CHANGED_FIELDS = %w[restricted_details].freeze
    OPERATIONS = %w[keep replace clear].freeze
    InvalidUpdate = Class.new(StandardError)

    def self.save!(vessel:, restricted_details:, actor:, request_id: nil)
      canonical_vessel = canonical_vessel(vessel)
      account = canonical_vessel&.account
      raise Authorization::RestrictedVesselPolicy::AccessDenied,
        Authorization::ACCESS_DENIED_MESSAGE unless account&.persisted?

      canonical_vessel.with_lock do
        account = canonical_vessel.account

        account.with_lock do
          authorized_vessel = Authorization::RestrictedVesselPolicy.new(user: actor).authorize_write!(canonical_vessel)
          record = VesselAccessInformation.find_or_initialize_by(asset_id: authorized_vessel.id)
          creating = record.new_record?
          # Rails' encrypted attribute type encrypts this value during serialization before the database write.
          # CodeQL does not model that framework boundary, so this assignment is not a plaintext storage sink.
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

    def self.update_fields!(vessel:, updates:, actor:, request_id: nil)
      canonical_vessel = canonical_vessel(vessel)
      account = canonical_vessel&.account
      raise Authorization::RestrictedVesselPolicy::AccessDenied,
        Authorization::ACCESS_DENIED_MESSAGE unless account&.persisted?

      canonical_vessel.with_lock do
        account = canonical_vessel.account

        account.with_lock do
          authorized_vessel = Authorization::RestrictedVesselPolicy.new(user: actor).authorize_write!(canonical_vessel)
          record = VesselAccessInformation.find_or_initialize_by(asset_id: authorized_vessel.id)
          fields = record.persisted? ? record.restricted_fields : {}
          replaced_fields = []
          cleared_fields = []

          normalize_updates(updates).each do |field, update|
            case update.fetch("operation")
            when "keep"
              next
            when "replace"
              replacement = update.fetch("value", "").to_s.strip
              validate_replacement!(record:, field:, replacement:)
              next if fields[field] == replacement

              fields[field] = replacement
              replaced_fields << field
            when "clear"
              next unless fields.key?(field)

              fields.delete(field)
              cleared_fields << field
            end
          end

          return record.persisted? ? record : nil if replaced_fields.empty? && cleared_fields.empty?

          creating = record.new_record?
          if fields.empty?
            record_clear_audit!(record:, actor:, account:, request_id:, fields: cleared_fields)
            record.destroy!
            return nil
          end

          # Rails' encrypted attribute type encrypts this versioned field payload during
          # serialization before the database write. No restricted value is stored on Asset.
          record.restricted_details = VesselAccessInformation.serialize_fields(fields)
          record.save!

          if replaced_fields.any?
            SecurityAudit::Recorder.record!(
              action: creating ? "vessel_access_information.created" : "vessel_access_information.updated",
              actor:,
              account:,
              target: record,
              request_id:,
              changed_fields: replaced_fields
            )
          end
          record_clear_audit!(record:, actor:, account:, request_id:, fields: cleared_fields)
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
    rescue StandardError => error
      Rails.logger.error(
        "Vessel access information denial audit failed: #{error.class}"
      )
    end
    private_class_method :record_denial

    def self.normalize_updates(updates)
      updates.to_h.each_with_object({}) do |(field, update), result|
        field = field.to_s
        raise InvalidUpdate, "Unknown restricted field." unless VesselAccessInformation::RESTRICTED_FIELD_NAMES.include?(field)

        normalized_update = update.to_h.stringify_keys
        operation = normalized_update.fetch("operation", "keep")
        raise InvalidUpdate, "Choose Keep existing, Replace, or Clear." unless OPERATIONS.include?(operation)
        if operation == "keep" && normalized_update.fetch("value", "").present?
          raise InvalidUpdate, "Remove the new value or choose Replace."
        end

        result[field] = normalized_update.slice("operation", "value")
      end
    end
    private_class_method :normalize_updates

    def self.validate_replacement!(record:, field:, replacement:)
      if replacement.blank?
        record.errors.add(field, "must be provided when Replace is selected")
        raise ActiveRecord::RecordInvalid, record
      end

      maximum = VesselAccessInformation::RESTRICTED_FIELD_DEFINITIONS.fetch(field).fetch(:maximum)
      return if replacement.length <= maximum

      record.errors.add(field, "is too long (maximum is #{maximum} characters)")
      raise ActiveRecord::RecordInvalid, record
    end
    private_class_method :validate_replacement!

    def self.record_clear_audit!(record:, actor:, account:, request_id:, fields:)
      return if fields.empty?

      SecurityAudit::Recorder.record!(
        action: "vessel_access_information.fields_cleared",
        actor:,
        account:,
        target: record,
        request_id:,
        changed_fields: fields
      )
    end
    private_class_method :record_clear_audit!

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
