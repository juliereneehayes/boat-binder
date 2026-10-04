class MfaEncryptionConfiguration
  PRIMARY_KEY_ENV = "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"
  PREVIOUS_PRIMARY_KEYS_ENV = "ACTIVE_RECORD_ENCRYPTION_PREVIOUS_PRIMARY_KEYS"
  KEY_DERIVATION_SALT_ENV = "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"
  MINIMUM_MATERIAL_BYTES = 32
  Configuration = Data.define(:primary_keys, :key_derivation_salt)

  class << self
    def build(environment: Rails.env, env: ENV, key_generator: Rails.application.key_generator)
      current_key = env[PRIMARY_KEY_ENV].presence
      key_derivation_salt = env[KEY_DERIVATION_SALT_ENV].presence

      if environment.to_s == "production"
        missing = [
          (PRIMARY_KEY_ENV unless current_key),
          (KEY_DERIVATION_SALT_ENV unless key_derivation_salt)
        ].compact
        raise KeyError, "Missing required MFA encryption configuration: #{missing.join(", ")}" if missing.any?
      else
        current_key ||= local_material(key_generator, "active-record-encryption-primary-v1")
        key_derivation_salt ||= local_material(key_generator, "active-record-encryption-salt-v1")
      end

      previous_keys = env.fetch(PREVIOUS_PRIMARY_KEYS_ENV, "").split(",").map(&:strip).compact_blank
      validate_material!(PRIMARY_KEY_ENV, current_key)
      validate_material!(KEY_DERIVATION_SALT_ENV, key_derivation_salt)
      previous_keys.each { |key| validate_material!(PREVIOUS_PRIMARY_KEYS_ENV, key) }
      if previous_keys.include?(current_key)
        raise ArgumentError, "#{PREVIOUS_PRIMARY_KEYS_ENV} must not include the current primary key"
      end

      Configuration.new(primary_keys: previous_keys + [ current_key ], key_derivation_salt:)
    end

    private

    def local_material(key_generator, purpose)
      key_generator.generate_key(purpose, MINIMUM_MATERIAL_BYTES).unpack1("H*")
    end

    def validate_material!(name, value)
      return if value.bytesize >= MINIMUM_MATERIAL_BYTES

      raise ArgumentError, "#{name} must contain at least #{MINIMUM_MATERIAL_BYTES} bytes"
    end
  end
end

mfa_encryption = MfaEncryptionConfiguration.build
ActiveRecord::Encryption.configure(
  primary_key: mfa_encryption.primary_keys,
  key_derivation_salt: mfa_encryption.key_derivation_salt,
  store_key_references: true,
  support_sha1_for_non_deterministic_encryption: false
)
