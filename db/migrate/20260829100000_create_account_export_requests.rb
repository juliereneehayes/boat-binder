class CreateAccountExportRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :account_export_requests do |t|
      t.references :account, null: false, foreign_key: true
      t.references :requester, null: false, foreign_key: { to_table: :users }
      t.string :lifecycle_context, null: false
      t.string :status, null: false, default: "requested"
      t.datetime :recipient_verified_at
      t.references :recipient_verified_by, foreign_key: { to_table: :users }
      t.datetime :scope_verified_at
      t.references :scope_verified_by, foreign_key: { to_table: :users }
      t.datetime :decided_at
      t.references :decided_by, foreign_key: { to_table: :users }
      t.datetime :fulfilled_at
      t.references :fulfilled_by, foreign_key: { to_table: :users }

      t.timestamps
    end

    add_index :account_export_requests,
      :account_id,
      unique: true,
      where: "status IN ('requested', 'approved')",
      name: "idx_account_export_requests_one_open_per_account"
    add_check_constraint :account_export_requests,
      "status IN ('requested', 'approved', 'declined', 'fulfilled')",
      name: "chk_account_export_requests_status"
    add_check_constraint :account_export_requests,
      <<~SQL.squish,
        lifecycle_context IN (
          'scheduled_cancellation',
          'payment_recovery_pending',
          'read_only_grace',
          'retained_inactive',
          'archive_eligible'
        )
      SQL
      name: "chk_account_export_requests_lifecycle_context"
  end
end
