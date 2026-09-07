class AddEmailVerificationLifecycleToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :email_verification_sent_at, :datetime
    add_column :users, :email_verified_at, :datetime
    add_check_constraint :users,
      "email_verified_at IS NULL OR email_verification_sent_at IS NOT NULL",
      name: "chk_users_email_verification_sequence"
  end
end
