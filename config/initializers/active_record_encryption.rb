# Derive purpose-separated Active Record encryption material from the existing
# Rails secret_key_base. No additional key is persisted in source control.
primary_key = Rails.application.key_generator.generate_key(
  "active-record-encryption-primary-v1",
  32
).unpack1("H*")
key_derivation_salt = Rails.application.key_generator.generate_key(
  "active-record-encryption-salt-v1",
  32
).unpack1("H*")

ActiveRecord::Encryption.configure(primary_key:, key_derivation_salt:)
