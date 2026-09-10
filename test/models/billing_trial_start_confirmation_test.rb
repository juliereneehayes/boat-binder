require "test_helper"

class BillingTrialStartConfirmationTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @previous_queue_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
    @account = create_account(name: "Confirmation Model")
    @subscription = @account.subscription
    @trial_started_at = Time.zone.local(2026, 9, 9, 12)
  end

  teardown do
    clear_enqueued_jobs
    ActiveJob::Base.queue_adapter = @previous_queue_adapter
  end

  test "enforces durable uniqueness by account external subscription and trial start" do
    confirmation = create_confirmation

    assert_raises(ActiveRecord::RecordInvalid) do
      create_confirmation
    end

    duplicate_attributes = confirmation.attributes.except("id", "created_at", "updated_at")
    assert_raises(ActiveRecord::RecordNotUnique) do
      BillingTrialStartConfirmation.insert_all!([ duplicate_attributes ])
    end
  end

  test "same external subscription may record a different authoritative trial start" do
    create_confirmation

    assert_difference -> { BillingTrialStartConfirmation.count }, 1 do
      create_confirmation(trial_started_at: @trial_started_at + 1.year)
    end
  end

  test "trial end must follow trial start" do
    confirmation = build_confirmation(trial_ends_at: @trial_started_at)

    assert_not confirmation.valid?
    assert_includes confirmation.errors[:trial_ends_at], "must be after the trial start"
  end

  test "a different job cannot claim a delivering confirmation even when the claim is old" do
    confirmation = create_confirmation
    confirmation.update!(status: "delivering", active_job_id: "active-job")
    confirmation.update_column(:updated_at, 1.year.ago)

    assert_not confirmation.claim_delivery!(job_id: "different-job")

    confirmation.reload
    assert_equal "delivering", confirmation.status
    assert_equal "active-job", confirmation.active_job_id
  end

  test "operator recovery resets only a delivering confirmation after a provider check" do
    confirmation = create_confirmation
    confirmation.update!(status: "delivering", active_job_id: "stranded-job")
    clear_enqueued_jobs

    assert_no_enqueued_jobs do
      assert confirmation.reset_stranded_delivery_after_provider_check!
    end

    confirmation.reload
    assert_equal "failed", confirmation.status
    assert_nil confirmation.active_job_id
    assert_not_nil confirmation.failed_at
    assert_equal BillingTrialStartConfirmation::OPERATOR_RECOVERY_ERROR_CODE,
      confirmation.error_code
  end

  test "operator recovery fails closed for confirmations that are not delivering" do
    confirmation = create_confirmation.reload

    %w[pending enqueued failed delivered skipped].each do |status|
      confirmation.update!(status:, active_job_id: "job-for-#{status}")

      assert_raises(BillingTrialStartConfirmation::InvalidDeliveryRecovery) do
        confirmation.reset_stranded_delivery_after_provider_check!
      end
      assert_equal status, confirmation.reload.status
      assert_equal "job-for-#{status}", confirmation.active_job_id
    end
  end

  test "delivery is enqueued only after the creating transaction commits" do
    assert_no_enqueued_jobs do
      ActiveRecord::Base.transaction do
        create_confirmation
        raise ActiveRecord::Rollback
      end
    end
    assert_equal 0, BillingTrialStartConfirmation.count

    assert_enqueued_with(job: Billing::TrialStartConfirmationDeliveryJob) do
      ActiveRecord::Base.transaction { create_confirmation }
    end
  end

  test "database constraints preserve supported status option and trial range" do
    constraints = ActiveRecord::Base.connection.check_constraints(:billing_trial_start_confirmations)
      .index_by(&:name)

    assert_match(/pending/, constraints.fetch("chk_trial_start_confirmations_status").expression)
    assert_match(/self_managed_monthly/, constraints.fetch("chk_trial_start_confirmations_option").expression)
    assert_match(/trial_ends_at > trial_started_at/,
      constraints.fetch("chk_trial_start_confirmations_trial_range").expression)
  end

  test "migration rollback refuses to discard canonical trial or delivery history" do
    confirmation = create_confirmation
    @subscription.update_column(:trial_started_at, @trial_started_at)
    migration = trial_confirmation_migration

    error = assert_raises(ActiveRecord::IrreversibleMigration) { migration.migrate(:down) }

    assert_includes error.message, "trial confirmation delivery history"
    assert ActiveRecord::Base.connection.table_exists?(:billing_trial_start_confirmations)
    assert ActiveRecord::Base.connection.column_exists?(:subscriptions, :trial_started_at)
    assert_equal confirmation.id, BillingTrialStartConfirmation.find(confirmation.id).id
  end

  test "migration rolls back cleanly before trial confirmation data exists" do
    BillingTrialStartConfirmation.delete_all
    Subscription.update_all(trial_started_at: nil)
    migration = trial_confirmation_migration

    migration.migrate(:down)
    assert_not ActiveRecord::Base.connection.table_exists?(:billing_trial_start_confirmations)
    assert_not ActiveRecord::Base.connection.column_exists?(:subscriptions, :trial_started_at)
  ensure
    unless ActiveRecord::Base.connection.table_exists?(:billing_trial_start_confirmations)
      migration&.migrate(:up)
      Subscription.reset_column_information
      BillingTrialStartConfirmation.reset_column_information
    end
  end

  private

  def create_confirmation(**attributes)
    build_confirmation(**attributes).tap(&:save!)
  end

  def build_confirmation(trial_started_at: @trial_started_at, trial_ends_at: trial_started_at + 7.days)
    BillingTrialStartConfirmation.new(
      account: @account,
      subscription: @subscription,
      external_subscription_id: "sub_confirmation_model",
      option_key: Billing::SubscriptionPlanCatalog::SELF_MANAGED_MONTHLY_KEY,
      trial_started_at:,
      trial_ends_at:
    )
  end

  def trial_confirmation_migration
    migration_paths = Dir.glob(
      Rails.root.join("db/migrate/*_create_billing_trial_start_confirmations.rb").to_s
    )
    assert_equal 1, migration_paths.length, "Expected exactly one trial-confirmation migration"
    require migration_paths.fetch(0)

    CreateBillingTrialStartConfirmations.new
  end
end
