class AddPendingEmailChangeToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :pending_email_address, :string
    add_column :users, :email_change_requested_at, :datetime
    add_check_constraint :users,
      "(pending_email_address IS NULL) = (email_change_requested_at IS NULL)",
      name: "chk_users_pending_email_change_pair"
  end
end
