require "test_helper"

class SubscriptionTest < ActiveSupport::TestCase
  test "Self Managed plan transition rejects an existing over-limit Account" do
    account = create_account(name: "Over-limit plan transition")
    first = create_user(email: "plan-owner-one@example.test", role: "owner")
    second = create_user(email: "plan-owner-two@example.test", role: "owner")
    create_account_membership(user: first, account: account)
    create_account_membership(user: second, account: account)

    account.subscription.assign_attributes(plan: "self_managed")

    assert_not account.subscription.save
    assert_includes account.subscription.errors[:plan], Billing::OwnerUserLimit::ERROR_MESSAGE
    assert_equal "legacy", account.subscription.reload.plan
  end

  test "defines plan and status vocabularies centrally" do
    subscription = Subscription.new(plan: "legacy", status: "trialing", provider: "local")

    assert_includes Subscription::PROVIDERS, "local"
    assert_includes Subscription::PROVIDERS, "stripe"
    assert_includes Subscription::PLANS, "legacy"
    assert_includes Subscription::PLANS, "self_managed"
    assert_includes Subscription::STATUSES, "pending_checkout"
    assert_includes Subscription::STATUSES, "past_due"
    assert subscription.trialing?

    subscription.status = "active"
    assert subscription.active?
  end

  test "pending Checkout attributes define a valid non-Stripe Self Managed state" do
    attributes = Subscription.pending_checkout_attributes
    subscription = Subscription.new(
      account: bare_account(name: "Pending Checkout Attributes"),
      **attributes
    )

    assert_equal Subscription::LOCAL_PROVIDER, attributes.fetch(:provider)
    assert_equal "self_managed", attributes.fetch(:plan)
    assert_equal Subscription::PENDING_CHECKOUT_STATUS, attributes.fetch(:status)
    assert subscription.pending_checkout?
    assert subscription.save
    assert_nil subscription.external_customer_id
    assert_nil subscription.external_subscription_id
  end

  test "pending Checkout predicate requires the exact local plan and status" do
    subscription = Subscription.new(Subscription.pending_checkout_attributes)
    assert subscription.pending_checkout?

    {
      provider: Subscription::STRIPE_PROVIDER,
      plan: "legacy",
      status: "active"
    }.each do |attribute, value|
      candidate = subscription.dup
      candidate.public_send("#{attribute}=", value)

      assert_not candidate.pending_checkout?, "#{attribute} should be part of the pending state"
    end
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

    assert_nil subscription.cancel_at
    assert_nil subscription.entitlement_ended_at
    assert_nil subscription.past_due_observed_at
    assert Subscription.columns_hash.fetch("cancel_at").null
    assert Subscription.columns_hash.fetch("entitlement_ended_at").null
    assert Subscription.columns_hash.fetch("past_due_observed_at").null
  end

  test "scheduled cancellation boundary prefers canonical cancel at and retains period-end compatibility" do
    now = Time.zone.local(2026, 8, 30, 12)
    subscription = create_account(name: "Scheduled cancellation predicates").subscription
    subscription.update!(
      status: "active",
      current_period_ends_at: now + 1.month,
      cancel_at_period_end: true
    )

    assert_equal now + 1.month, subscription.scheduled_cancellation_at
    assert subscription.scheduled_cancellation?(now:)

    subscription.update!(cancel_at_period_end: false, cancel_at: now + 2.weeks)
    assert_equal now + 2.weeks, subscription.scheduled_cancellation_at
    assert subscription.scheduled_cancellation?(now:)

    subscription.update!(cancel_at: nil)
    assert_nil subscription.scheduled_cancellation_at
    assert_not subscription.scheduled_cancellation?(now:)
  end

  test "cancel at migration rollback refuses to discard canonical boundaries" do
    subscription = create_account(name: "Canonical cancel at rollback").subscription
    cancel_at = 1.month.from_now
    subscription.update!(cancel_at:)
    migration = cancel_at_migration

    error = assert_raises(ActiveRecord::IrreversibleMigration) do
      migration.migrate(:down)
    end

    assert_includes error.message, "canonical cancellation boundaries exist"
    assert ActiveRecord::Base.connection.column_exists?(:subscriptions, :cancel_at)
    assert_equal cancel_at.to_i, subscription.reload.cancel_at.to_i
  end

  test "cancel at migration rolls back when no canonical boundaries exist" do
    Subscription.update_all(cancel_at: nil)
    migration = cancel_at_migration

    migration.migrate(:down)
    Subscription.reset_column_information
    assert_not ActiveRecord::Base.connection.column_exists?(:subscriptions, :cancel_at)
  ensure
    unless ActiveRecord::Base.connection.column_exists?(:subscriptions, :cancel_at)
      migration&.migrate(:up)
      Subscription.reset_column_information
    end
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

  test "database status constraint accepts pending Checkout and rejects unknown statuses" do
    pending_subscription = Subscription.create!(
      account: bare_account(name: "Pending Checkout Database Constraint"),
      **Subscription.pending_checkout_attributes
    )
    assert_equal Subscription::PENDING_CHECKOUT_STATUS, pending_subscription.reload.status

    assert_raises(ActiveRecord::StatementInvalid) do
      Subscription.transaction(requires_new: true) do
        pending_subscription.update_columns(status: "unknown_checkout_status")
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

  test "pending Checkout status rollback is refused before changing the constraint when records exist" do
    subscription = Subscription.create!(
      account: bare_account(name: "Pending Checkout Rollback Protection"),
      **Subscription.pending_checkout_attributes
    )
    migration = pending_checkout_status_migration

    error = assert_raises(ActiveRecord::IrreversibleMigration) do
      migration.migrate(:down)
    end

    assert_includes error.message, "subscriptions still use that status"
    assert_equal Subscription::PENDING_CHECKOUT_STATUS, subscription.reload.status
    assert_match(/pending_checkout/, subscription_status_constraint.expression)
  end

  test "pending Checkout status migration rolls back without altering existing rows when unused" do
    assert_not Subscription.exists?(status: Subscription::PENDING_CHECKOUT_STATUS)
    existing_subscription = create_account(name: "Existing Status Migration Account").subscription
    migration = pending_checkout_status_migration

    migration.migrate(:down)

    assert_no_match(/pending_checkout/, subscription_status_constraint.expression)
    assert_equal "active", existing_subscription.reload.status
  ensure
    migration&.migrate(:up) unless subscription_status_constraint.expression.match?(/pending_checkout/)
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

  def cancel_at_migration
    migration_paths = Dir.glob(
      Rails.root.join("db/migrate/*_add_cancel_at_to_subscriptions.rb").to_s
    )
    assert_equal 1, migration_paths.length, "Expected exactly one cancel-at migration"
    require migration_paths.fetch(0)

    AddCancelAtToSubscriptions.new
  end

  def pending_checkout_status_migration
    migration_paths = Dir.glob(
      Rails.root.join("db/migrate/*_add_pending_checkout_to_subscription_statuses.rb").to_s
    )
    assert_equal 1, migration_paths.length, "Expected exactly one pending Checkout status migration"
    require migration_paths.fetch(0)

    AddPendingCheckoutToSubscriptionStatuses.new
  end

  def subscription_plan_constraint
    ActiveRecord::Base.connection.check_constraints(:subscriptions).find do |constraint|
      constraint.name == "chk_subscriptions_plan"
    end
  end

  def subscription_status_constraint
    ActiveRecord::Base.connection.check_constraints(:subscriptions).find do |constraint|
      constraint.name == "chk_subscriptions_status"
    end
  end
end
