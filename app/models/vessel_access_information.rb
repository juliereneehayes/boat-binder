class VesselAccessInformation < ApplicationRecord
  MAX_RESTRICTED_DETAILS_LENGTH = 20_000
  MAX_SERIALIZED_PAYLOAD_LENGTH = 170_000
  PAYLOAD_SCHEMA = "boat_binder.vessel_access_information"
  PAYLOAD_VERSION = 1
  PayloadError = Class.new(StandardError)
  UnsupportedPayloadVersion = Class.new(PayloadError)
  InvalidPayload = Class.new(PayloadError)
  PayloadTooLarge = Class.new(PayloadError)
  RESTRICTED_FIELD_DEFINITIONS = {
    "marina_gate_code" => {
      label: "Marina gate / access code",
      group: "Marina Access",
      multiline: false,
      maximum: 255
    },
    "marina_access_instructions" => {
      label: "Marina access instructions",
      group: "Marina Access",
      multiline: true,
      maximum: 5_000
    },
    "physical_key_location" => {
      label: "Physical key location",
      group: "Vessel Access",
      multiline: true,
      maximum: 2_000
    },
    "lockbox_code" => {
      label: "Lockbox code",
      group: "Vessel Access",
      multiline: false,
      maximum: 255
    },
    "alarm_security_code" => {
      label: "Alarm / security code",
      group: "Vessel Access",
      multiline: false,
      maximum: 255
    },
    "additional_vessel_access_notes" => {
      label: "Additional vessel access notes",
      group: "Vessel Access",
      multiline: true,
      maximum: 10_000
    }
  }.freeze
  RESTRICTED_FIELD_NAMES = RESTRICTED_FIELD_DEFINITIONS.keys.freeze
  PAYLOAD_FIELD_NAME_FORMAT = /\A[a-z][a-z0-9_]*\z/

  self.table_name = "vessel_access_information"

  belongs_to :vessel,
    -> { vessels },
    class_name: "Asset",
    foreign_key: :asset_id,
    inverse_of: :vessel_access_information

  encrypts :restricted_details
  attr_readonly :asset_id

  delegate :account, :account_id, to: :vessel

  validates :asset_id, uniqueness: true
  validates :restricted_details, presence: true
  validate :restricted_details_size
  validate :vessel_asset_type

  def restricted_fields
    self.class.deserialize_fields(restricted_details)
  end

  def restricted_field(field_name)
    field_name = field_name.to_s
    restricted_fields[field_name] if RESTRICTED_FIELD_NAMES.include?(field_name)
  end

  def restricted_field_names
    restricted_fields.select do |field, value|
      RESTRICTED_FIELD_NAMES.include?(field) && value.present?
    end.keys
  end

  def self.serialize_fields(fields)
    normalized = fields.to_h.each_with_object({}) do |(field, value), result|
      field = field.to_s
      raise ArgumentError, "invalid restricted field name" unless PAYLOAD_FIELD_NAME_FORMAT.match?(field)

      normalized_value = value.to_s
      next if normalized_value.blank?

      maximum = serialized_field_maximum(field)
      raise ArgumentError, "#{field} is too long" if normalized_value.length > maximum

      result[field] = normalized_value
    end

    payload = JSON.generate(
      "schema" => PAYLOAD_SCHEMA,
      "version" => PAYLOAD_VERSION,
      "fields" => normalized.sort.to_h
    )
    if payload.length > MAX_SERIALIZED_PAYLOAD_LENGTH || payload.bytesize > MAX_SERIALIZED_PAYLOAD_LENGTH
      raise PayloadTooLarge, "restricted access payload is too large"
    end

    payload
  end

  def self.deserialize_fields(value)
    raw_value = value.to_s
    parsed = JSON.parse(raw_value)
    return legacy_fields(raw_value) unless parsed.is_a?(Hash) && parsed["schema"] == PAYLOAD_SCHEMA

    unless parsed["version"] == PAYLOAD_VERSION
      raise UnsupportedPayloadVersion, "unsupported restricted access payload version"
    end

    fields = parsed["fields"]
    raise InvalidPayload, "invalid restricted access payload" unless fields.is_a?(Hash)

    fields.each_with_object({}) do |(field, field_value), result|
      unless field.is_a?(String) && PAYLOAD_FIELD_NAME_FORMAT.match?(field) && field_value.is_a?(String)
        raise InvalidPayload, "invalid restricted access payload"
      end
      if field_value.length > serialized_field_maximum(field)
        raise InvalidPayload, "invalid restricted access payload"
      end
      next if field_value.blank?

      result[field] = field_value
    end
  rescue JSON::ParserError
    legacy_fields(raw_value)
  end

  def self.legacy_fields(raw_value)
    return {} if raw_value.blank?

    { "additional_vessel_access_notes" => raw_value }
  end
  private_class_method :legacy_fields

  def self.serialized_field_maximum(field)
    return MAX_RESTRICTED_DETAILS_LENGTH if field == "additional_vessel_access_notes"

    RESTRICTED_FIELD_DEFINITIONS.dig(field, :maximum) || MAX_RESTRICTED_DETAILS_LENGTH
  end
  private_class_method :serialized_field_maximum

  private

  def restricted_details_size
    value = restricted_details.to_s
    if supported_payload?(value)
      return if value.length <= MAX_SERIALIZED_PAYLOAD_LENGTH && value.bytesize <= MAX_SERIALIZED_PAYLOAD_LENGTH

      errors.add(:restricted_details, "serialized payload is too large")
    elsif value.length > MAX_RESTRICTED_DETAILS_LENGTH
      errors.add(:restricted_details, "is too long (maximum is #{MAX_RESTRICTED_DETAILS_LENGTH} characters)")
    end
  end

  def supported_payload?(value)
    parsed = JSON.parse(value)
    parsed.is_a?(Hash) && parsed["schema"] == PAYLOAD_SCHEMA &&
      parsed["version"] == PAYLOAD_VERSION && parsed["fields"].is_a?(Hash)
  rescue JSON::ParserError
    false
  end

  def vessel_asset_type
    errors.add(:vessel, "must be a Vessel") if vessel.present? && vessel.asset_type != "vessel"
  end
end
