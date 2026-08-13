class AddBillingCheckoutAttempts < ActiveRecord::Migration[8.1]
  ACTIVE_ATTEMPT_STATUSES = %w[creating open replacing submitted].freeze
  ATTEMPT_STATUSES = (ACTIVE_ATTEMPT_STATUSES + %w[completed canceled expired replaced]).freeze

  def change
    create_table :billing_checkout_attempts do |t|
      t.references :account, null: false, foreign_key: true
      t.string :option_key, null: false
      t.string :stripe_customer_id, null: false
      t.string :stripe_checkout_session_id
      t.string :idempotency_key, null: false
      t.string :status, null: false, default: "creating"
      t.timestamps
    end

    add_index :billing_checkout_attempts, :idempotency_key, unique: true
    add_index :billing_checkout_attempts,
      :stripe_checkout_session_id,
      unique: true,
      where: "stripe_checkout_session_id IS NOT NULL"
    add_index :billing_checkout_attempts, :stripe_customer_id
    add_index :billing_checkout_attempts,
      :account_id,
      unique: true,
      where: "status IN (#{quoted_values(ACTIVE_ATTEMPT_STATUSES)})",
      name: "idx_billing_checkout_attempts_one_active_per_account"
    add_check_constraint :billing_checkout_attempts,
      "status IN (#{quoted_values(ATTEMPT_STATUSES)})",
      name: "chk_billing_checkout_attempts_status"
  end

  private

  def quoted_values(values)
    values.map { |value| quote(value) }.join(", ")
  end
end
