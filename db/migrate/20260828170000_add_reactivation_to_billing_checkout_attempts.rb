class AddReactivationToBillingCheckoutAttempts < ActiveRecord::Migration[8.1]
  def up
    add_column :billing_checkout_attempts, :replaces_external_subscription_id, :string
    add_check_constraint :billing_checkout_attempts,
      "replaces_external_subscription_id IS NULL OR replaces_external_subscription_id <> ''",
      name: "chk_billing_checkout_attempts_replacement_present"
  end

  def down
    if select_value(<<~SQL).to_i.positive?
      SELECT COUNT(*)
      FROM billing_checkout_attempts
      WHERE replaces_external_subscription_id IS NOT NULL
    SQL
      raise ActiveRecord::IrreversibleMigration,
        "Cannot remove reactivation correlation while replacement attempts exist"
    end

    remove_check_constraint :billing_checkout_attempts,
      name: "chk_billing_checkout_attempts_replacement_present"
    remove_column :billing_checkout_attempts, :replaces_external_subscription_id
  end
end
