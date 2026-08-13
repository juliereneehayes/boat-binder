require "test_helper"

class BillingCheckoutAttemptTest < ActiveSupport::TestCase
  test "only one active Checkout attempt is allowed per account" do
    account = create_account(name: "One Active Checkout")
    create_attempt(account: account, status: "open")

    duplicate = build_attempt(account: account, status: "creating")

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:account_id], "already has an active Checkout attempt"
  end

  test "database unique index protects the one active attempt invariant" do
    account = create_account(name: "Checkout Database Invariant")
    create_attempt(account: account, status: "open")
    timestamp = Time.current

    assert_raises(ActiveRecord::RecordNotUnique) do
      BillingCheckoutAttempt.insert_all!([
        {
          account_id: account.id,
          option_key: "self_managed_monthly",
          stripe_customer_id: "cus_database_duplicate",
          stripe_checkout_session_id: "cs_database_duplicate",
          idempotency_key: SecureRandom.uuid,
          status: "creating",
          created_at: timestamp,
          updated_at: timestamp
        }
      ])
    end
  end

  test "replacing remains active for the database uniqueness invariant" do
    account = create_account(name: "Replacing Checkout Database Invariant")
    create_attempt(account: account, status: "replacing")
    timestamp = Time.current

    assert_raises(ActiveRecord::RecordNotUnique) do
      BillingCheckoutAttempt.insert_all!([
        {
          account_id: account.id,
          option_key: "self_managed_annual",
          stripe_customer_id: "cus_replacing_duplicate",
          idempotency_key: SecureRandom.uuid,
          status: "creating",
          created_at: timestamp,
          updated_at: timestamp
        }
      ])
    end
  end

  test "completed canceled expired and replaced attempts do not block a new attempt" do
    account = create_account(name: "Inactive Checkout Attempts")

    %w[completed canceled expired replaced].each do |status|
      create_attempt(account: account, status: status)
    end

    assert build_attempt(account: account, status: "creating").valid?
  end

  test "status check constraint rejects unsupported values" do
    attempt = create_attempt(status: "open")

    assert_raises(ActiveRecord::StatementInvalid) do
      BillingCheckoutAttempt.transaction(requires_new: true) do
        attempt.update_column(:status, "unknown")
      end
    end
  end

  test "Stripe Customer lookup uses a direct non-unique index" do
    indexes = ActiveRecord::Base.connection.indexes(:billing_checkout_attempts)
    customer_indexes = indexes.select { |index| index.columns.include?("stripe_customer_id") }

    assert_equal 1, customer_indexes.length
    assert_equal [ "stripe_customer_id" ], customer_indexes.first.columns
    assert_not customer_indexes.first.unique
  end

  test "completed attempts cannot regress to an active state" do
    attempt = create_attempt(status: "completed")

    BillingCheckoutAttempt::ACTIVE_STATUSES.each do |status|
      attempt.status = status

      assert_not attempt.valid?
      assert_includes attempt.errors[:status], "cannot transition from completed to #{status}"
    end
  end

  private

  def create_attempt(account: create_account, status:)
    build_attempt(account: account, status: status).tap(&:save!)
  end

  def build_attempt(account:, status:)
    BillingCheckoutAttempt.new(
      account: account,
      option_key: "self_managed_monthly",
      stripe_customer_id: "cus_#{SecureRandom.hex(4)}",
      stripe_checkout_session_id: "cs_#{SecureRandom.hex(4)}",
      idempotency_key: SecureRandom.uuid,
      status: status
    )
  end
end
