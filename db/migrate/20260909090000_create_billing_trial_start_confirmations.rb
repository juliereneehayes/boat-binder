class CreateBillingTrialStartConfirmations < ActiveRecord::Migration[8.1]
  def up
    add_column :subscriptions, :trial_started_at, :datetime

    create_table :billing_trial_start_confirmations do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :subscription, null: false, foreign_key: { on_delete: :cascade }
      t.string :external_subscription_id, null: false
      t.string :option_key, null: false
      t.datetime :trial_started_at, null: false
      t.datetime :trial_ends_at, null: false
      t.string :status, null: false, default: "pending"
      t.string :active_job_id
      t.datetime :enqueued_at
      t.datetime :delivered_at
      t.datetime :skipped_at
      t.datetime :failed_at
      t.string :error_code
      t.timestamps
    end

    add_index :billing_trial_start_confirmations,
      %i[account_id external_subscription_id trial_started_at],
      unique: true,
      name: "idx_trial_start_confirmations_dedupe"
    add_index :billing_trial_start_confirmations, :status
    add_check_constraint :billing_trial_start_confirmations,
      "external_subscription_id <> ''",
      name: "chk_trial_start_confirmations_subscription"
    add_check_constraint :billing_trial_start_confirmations,
      "option_key IN ('self_managed_monthly', 'self_managed_annual')",
      name: "chk_trial_start_confirmations_option"
    add_check_constraint :billing_trial_start_confirmations,
      "status IN ('pending', 'enqueued', 'delivering', 'delivered', 'skipped', 'failed')",
      name: "chk_trial_start_confirmations_status"
    add_check_constraint :billing_trial_start_confirmations,
      "trial_ends_at > trial_started_at",
      name: "chk_trial_start_confirmations_trial_range"
  end

  def down
    if select_value("SELECT 1 FROM billing_trial_start_confirmations LIMIT 1")
      raise ActiveRecord::IrreversibleMigration,
        "Cannot remove trial confirmation delivery history while records exist"
    end
    if select_value("SELECT 1 FROM subscriptions WHERE trial_started_at IS NOT NULL LIMIT 1")
      raise ActiveRecord::IrreversibleMigration,
        "Cannot remove canonical subscription trial starts while values exist"
    end

    drop_table :billing_trial_start_confirmations
    remove_column :subscriptions, :trial_started_at
  end
end
