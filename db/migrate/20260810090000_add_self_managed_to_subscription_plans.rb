class AddSelfManagedToSubscriptionPlans < ActiveRecord::Migration[8.1]
  PLANS = %w[legacy self_managed starter professional].freeze
  SELF_MANAGED_PLAN = "self_managed"

  def up
    remove_check_constraint :subscriptions, name: "chk_subscriptions_plan"
    add_check_constraint :subscriptions, plan_constraint_expression, name: "chk_subscriptions_plan"
  end

  def down
    if self_managed_subscriptions_exist?
      raise ActiveRecord::IrreversibleMigration,
        "Cannot remove self-managed plan support while self-managed subscriptions exist."
    end

    remove_check_constraint :subscriptions, name: "chk_subscriptions_plan"
    add_check_constraint :subscriptions,
      "plan IN ('legacy', 'starter', 'professional')",
      name: "chk_subscriptions_plan"
  end

  private

  def plan_constraint_expression
    quoted_plans = PLANS.map { |plan| quote(plan) }.join(", ")
    "plan IN (#{quoted_plans})"
  end

  def self_managed_subscriptions_exist?
    select_value(<<~SQL).present?
      SELECT 1
      FROM subscriptions
      WHERE plan = #{quote(SELF_MANAGED_PLAN)}
      LIMIT 1
    SQL
  end
end
