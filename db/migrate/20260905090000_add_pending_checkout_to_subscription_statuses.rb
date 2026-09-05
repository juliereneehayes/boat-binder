class AddPendingCheckoutToSubscriptionStatuses < ActiveRecord::Migration[8.1]
  CONSTRAINT_NAME = "chk_subscriptions_status"
  PREVIOUS_STATUSES = %w[legacy trialing active past_due canceled expired suspended].freeze
  CURRENT_STATUSES = [ "legacy", "pending_checkout", "trialing", "active", "past_due", "canceled", "expired", "suspended" ].freeze

  def up
    replace_status_constraint(CURRENT_STATUSES)
  end

  def down
    if select_value(<<~SQL.squish)
      SELECT 1
      FROM subscriptions
      WHERE status = #{quote("pending_checkout")}
      LIMIT 1
    SQL
      raise ActiveRecord::IrreversibleMigration,
        "Cannot remove pending_checkout while subscriptions still use that status"
    end

    replace_status_constraint(PREVIOUS_STATUSES)
  end

  private

  def replace_status_constraint(statuses)
    remove_check_constraint :subscriptions, name: CONSTRAINT_NAME
    quoted_statuses = statuses.map { |status| quote(status) }.join(", ")
    add_check_constraint :subscriptions,
      "status IN (#{quoted_statuses})",
      name: CONSTRAINT_NAME
  end
end
