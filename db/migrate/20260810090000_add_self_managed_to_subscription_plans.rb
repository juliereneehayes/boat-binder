class AddSelfManagedToSubscriptionPlans < ActiveRecord::Migration[8.1]
  PLANS = %w[legacy self_managed starter professional].freeze

  def up
    remove_check_constraint :subscriptions, name: "chk_subscriptions_plan"
    add_check_constraint :subscriptions, plan_constraint_expression, name: "chk_subscriptions_plan"
  end

  def down
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
end
