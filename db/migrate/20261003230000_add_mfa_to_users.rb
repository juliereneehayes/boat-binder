class AddMfaToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :mfa_totp_secret, :text
    add_column :users, :mfa_enrolled_at, :datetime
    add_column :users, :mfa_last_accepted_timestep, :bigint
    add_column :users, :mfa_recovery_code_digests, :text, array: true, default: [], null: false

    add_check_constraint :users,
      "mfa_enrolled_at IS NULL OR mfa_totp_secret IS NOT NULL",
      name: "chk_users_mfa_enrollment_has_secret"
    add_check_constraint :users,
      "mfa_last_accepted_timestep IS NULL OR mfa_enrolled_at IS NOT NULL",
      name: "chk_users_mfa_timestep_requires_enrollment"
    add_check_constraint :users,
      "mfa_enrolled_at IS NOT NULL OR cardinality(mfa_recovery_code_digests) = 0",
      name: "chk_users_mfa_recovery_requires_enrollment"
  end
end
