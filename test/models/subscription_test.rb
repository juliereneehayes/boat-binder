require "test_helper"

class SubscriptionTest < ActiveSupport::TestCase
  test "defines plan and status vocabularies centrally" do
    subscription = Subscription.new(plan: "legacy", status: "trialing", provider: "local")

    assert_includes Subscription::PROVIDERS, "local"
    assert_includes Subscription::PROVIDERS, "stripe"
    assert_includes Subscription::PLANS, "legacy"
    assert_includes Subscription::PLANS, "self_managed"
    assert_includes Subscription::STATUSES, "past_due"
    assert subscription.trialing?

    subscription.status = "active"
    assert subscription.active?
  end

  test "status and provider predicates describe local and external subscriptions" do
    subscription = Subscription.new(plan: "legacy", status: "past_due", provider: "local")

    assert subscription.past_due?
    assert_not subscription.managed_externally?

    subscription.status = "canceled"
    subscription.provider = "stripe"

    assert subscription.canceled?
    assert subscription.managed_externally?
  end

  test "local subscriptions do not fabricate Stripe lifecycle timing" do
    subscription = create_account(name: "Local lifecycle timing").subscription

    assert_nil subscription.entitlement_ended_at
    assert_nil subscription.past_due_observed_at
    assert Subscription.columns_hash.fetch("entitlement_ended_at").null
    assert Subscription.columns_hash.fetch("past_due_observed_at").null
  end

  test "lifecycle predicates are status specific" do
    subscription = Subscription.new(plan: "legacy", status: "active", provider: "local")

    {
      active: "active",
      trialing: "trialing",
      past_due: "past_due",
      canceled: "canceled",
      expired: "expired",
      suspended: "suspended"
    }.each do |predicate, status|
      Subscription::STATUSES.each do |candidate_status|
        subscription.status = candidate_status

        assert_equal candidate_status == status, subscription.public_send("#{predicate}?")
      end
    end
  end

  test "provider validation accepts only supported providers" do
    %w[local stripe].each do |provider|
      subscription = Subscription.new(
        account: bare_account(name: "Provider #{provider}"),
        plan: "legacy",
        status: "active",
        provider: provider
      )

      assert subscription.valid?, "#{provider} should be a valid provider"
      assert subscription.save, "#{provider} should satisfy database provider constraints"
    end

    [ nil, "", "LOCAL", "Stripe", "strpie", "paypal" ].each do |provider|
      subscription = Subscription.new(
        account: bare_account(name: "Invalid provider #{provider.inspect}"),
        plan: "legacy",
        status: "active",
        provider: provider
      )

      assert_not subscription.valid?, "#{provider.inspect} should be rejected"
      assert_includes subscription.errors[:provider], "is not included in the list"
    end
  end

  test "migration backfills existing accounts without application models" do
    migration_paths = Dir.glob(Rails.root.join("db/migrate/*_create_subscriptions.rb").to_s)
    assert_equal 1, migration_paths.length, "Expected exactly one create_subscriptions migration"

    migration_source = File.read(migration_paths.fetch(0))

    refute_match(/\bAccount\.(reset_column_information|where|update_all|find_each|all|find_by)/, migration_source)
    refute_match(/\bSubscription\.(reset_column_information|where|update_all|find_each|all|find_by)/, migration_source)
    assert_includes migration_source, "INSERT INTO subscriptions"
    assert_includes migration_source, "SELECT accounts.id"
    assert_includes migration_source, "'legacy'"
    assert_includes migration_source, "'active'"
  end

  test "database rejects unsupported providers when validations are bypassed" do
    account = bare_account(name: "Invalid Provider Database Check")
    timestamp = Time.current

    assert_raises(ActiveRecord::StatementInvalid) do
      Subscription.transaction(requires_new: true) do
        Subscription.insert_all!([
          {
            account_id: account.id,
            plan: "legacy",
            status: "active",
            provider: "paypal",
            created_at: timestamp,
            updated_at: timestamp
          }
        ])
      end
    end
  end

  test "database rejects duplicate subscriptions for an account" do
    account = create_account
    timestamp = Time.current

    assert_raises(ActiveRecord::RecordNotUnique) do
      Subscription.insert_all!([
        {
          account_id: account.id,
          plan: "legacy",
          status: "active",
          provider: "local",
          created_at: timestamp,
          updated_at: timestamp
        }
      ])
    end
  end

  test "external subscription id uniqueness allows multiple nil values" do
    first = Subscription.create!(
      account: bare_account(name: "Nil External Subscription One"),
      plan: "legacy",
      status: "active",
      provider: "stripe",
      external_subscription_id: nil
    )
    second = Subscription.create!(
      account: bare_account(name: "Nil External Subscription Two"),
      plan: "legacy",
      status: "active",
      provider: "stripe",
      external_subscription_id: nil
    )

    assert_nil first.external_subscription_id
    assert_nil second.external_subscription_id
  end

  test "external subscription id is unique within provider at model level" do
    Subscription.create!(
      account: bare_account(name: "Stripe External Subscription One"),
      plan: "professional",
      status: "active",
      provider: "stripe",
      external_subscription_id: "sub_duplicate"
    )

    duplicate = Subscription.new(
      account: bare_account(name: "Stripe External Subscription Two"),
      plan: "professional",
      status: "active",
      provider: "stripe",
      external_subscription_id: "sub_duplicate"
    )

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:external_subscription_id], "has already been taken"
  end

  test "external identifier indexes match database integrity expectations" do
    indexes = ActiveRecord::Base.connection.indexes(:subscriptions)

    customer_lookup_index = indexes.find do |index|
      index.columns == %w[provider external_customer_id]
    end
    assert customer_lookup_index
    assert_not customer_lookup_index.unique
    assert_match(/external_customer_id IS NOT NULL/, customer_lookup_index.where.to_s)

    subscription_lookup_index = indexes.find do |index|
      index.columns == %w[provider external_subscription_id]
    end
    assert subscription_lookup_index
    assert subscription_lookup_index.unique
    assert_match(/external_subscription_id IS NOT NULL/, subscription_lookup_index.where.to_s)
  end

  test "provider check constraint allows only supported provider values" do
    constraints = ActiveRecord::Base.connection.check_constraints(:subscriptions)
    provider_constraint = constraints.find { |constraint| constraint.name == "chk_subscriptions_provider" }

    assert provider_constraint
    assert_match(/provider.*local/, provider_constraint.expression)
    assert_match(/provider.*stripe/, provider_constraint.expression)
  end

  test "plan check constraint allows self managed subscriptions" do
    subscription = Subscription.create!(
      account: bare_account(name: "Self Managed Subscription"),
      plan: "self_managed",
      status: "trialing",
      provider: "stripe",
      external_subscription_id: "sub_self_managed"
    )

    assert_equal "self_managed", subscription.plan
    assert_equal "Self managed", subscription.plan_label

    constraints = ActiveRecord::Base.connection.check_constraints(:subscriptions)
    plan_constraint = constraints.find { |constraint| constraint.name == "chk_subscriptions_plan" }

    assert plan_constraint
    assert_match(/legacy/, plan_constraint.expression)
    assert_match(/self_managed/, plan_constraint.expression)
  end

  test "plan migration rollback is refused before changing the constraint when self managed records exist" do
    subscription = Subscription.create!(
      account: bare_account(name: "Self Managed Rollback Protection"),
      plan: "self_managed",
      status: "trialing",
      provider: "stripe",
      external_subscription_id: "sub_self_managed_rollback"
    )
    migration = self_managed_plan_migration

    error = assert_raises(ActiveRecord::IrreversibleMigration) do
      migration.migrate(:down)
    end

    assert_includes error.message, "self-managed subscriptions exist"
    assert_equal "self_managed", subscription.reload.plan
    assert_match(/self_managed/, subscription_plan_constraint.expression)
  end

  test "plan migration rollback restores the old constraint when no self managed records exist" do
    assert_not Subscription.exists?(plan: "self_managed")
    migration = self_managed_plan_migration

    migration.migrate(:down)

    assert_no_match(/self_managed/, subscription_plan_constraint.expression)
  ensure
    migration&.migrate(:up) unless subscription_plan_constraint.expression.match?(/self_managed/)
  end

  private

  def bare_account(name:)
    Account.create!(name: name, account_type: "client", time_zone: Account::DEFAULT_TIME_ZONE)
  end

  def self_managed_plan_migration
    migration_paths = Dir.glob(
      Rails.root.join("db/migrate/*_add_self_managed_to_subscription_plans.rb").to_s
    )
    assert_equal 1, migration_paths.length, "Expected exactly one self-managed plan migration"
    require migration_paths.fetch(0)

    AddSelfManagedToSubscriptionPlans.new
  end

  def subscription_plan_constraint
    ActiveRecord::Base.connection.check_constraints(:subscriptions).find do |constraint|
      constraint.name == "chk_subscriptions_plan"
    end
  end
end
