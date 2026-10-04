class AddMfaReenrollmentStartedAtToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :mfa_reenrollment_started_at, :datetime

    add_check_constraint :users,
      "mfa_reenrollment_started_at IS NULL OR " \
        "(mfa_enrolled_at IS NULL AND mfa_totp_secret IS NOT NULL)",
      name: "chk_users_mfa_reenrollment_is_pending"
  end
end
