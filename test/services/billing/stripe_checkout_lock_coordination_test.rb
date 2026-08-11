require "test_helper"
require "timeout"

module Billing
  class StripeCheckoutLockCoordinationTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    SECRET_KEY = "sk_test_checkout_locking"
    MONTHLY_PRICE_ID = "price_checkout_locking_monthly"
    ANNUAL_PRICE_ID = "price_checkout_locking_annual"

    setup do
      @account = create_account(name: "Checkout Locking #{SecureRandom.hex(6)}")
      @previous_secret_key = Rails.configuration.x.stripe.secret_key
      @previous_monthly_price_id = Rails.configuration.x.stripe.self_managed_monthly_price_id
      @previous_annual_price_id = Rails.configuration.x.stripe.self_managed_annual_price_id
      Rails.configuration.x.stripe.secret_key = SECRET_KEY
      Rails.configuration.x.stripe.self_managed_monthly_price_id = MONTHLY_PRICE_ID
      Rails.configuration.x.stripe.self_managed_annual_price_id = ANNUAL_PRICE_ID
    end

    teardown do
      @account&.destroy!
      Rails.configuration.x.stripe.secret_key = @previous_secret_key
      Rails.configuration.x.stripe.self_managed_monthly_price_id = @previous_monthly_price_id
      Rails.configuration.x.stripe.self_managed_annual_price_id = @previous_annual_price_id
    end

    test "webhook completion wins while Checkout is waiting on a Session retrieve" do
      attempt = create_attempt(customer_id: "cus_lock_webhook", session_id: "cs_lock_webhook")
      retrieve_started = Queue.new
      release_retrieve = Queue.new
      network_transaction_state = Queue.new
      checkout_session_factory = method(:checkout_session)

      with_stripe_methods(
        customer_create: ->(*) { raise "Stripe Customer creation was unexpected" },
        session_create: ->(*) { raise "Stripe Session creation was unexpected" },
        session_retrieve: ->(*) {
          network_transaction_state << ActiveRecord::Base.connection.transaction_open?
          retrieve_started << true
          release_retrieve.pop
          checkout_session_factory.call(id: attempt.stripe_checkout_session_id, status: "complete")
        }
      ) do
        creator_thread, creator_result = run_in_thread { create_checkout }
        Timeout.timeout(5) { retrieve_started.pop }

        webhook_thread, webhook_result = run_in_thread do
          StripeCheckoutCompletionSynchronizer.call(completed_checkout_session(attempt))
        end
        assert webhook_thread.join(5), "webhook synchronization deadlocked behind Checkout"
        assert_thread_succeeded(webhook_result)

        release_retrieve << true
        assert creator_thread.join(5), "Checkout did not resume after webhook synchronization"
        error = assert_thread_failed(creator_result)

        assert_instance_of StripeCheckoutSessionCreator::InvalidAccountError, error
      ensure
        release_retrieve << true if creator_thread&.alive?
        creator_thread&.join(1)
      end

      assert_equal false, network_transaction_state.pop
      assert_equal "completed", attempt.reload.status
      assert_equal "sub_lock_webhook", @account.subscription.reload.external_subscription_id
      assert_equal 0, @account.billing_checkout_attempts.active.count
    end

    test "concurrent Checkout requests converge on one attempt and idempotent Session" do
      session_calls = Queue.new
      release_sessions = Queue.new
      checkout_session_factory = method(:checkout_session)

      with_stripe_methods(
        customer_create: ->(*) { Stripe::Customer.construct_from(id: "cus_concurrent_checkout") },
        session_create: ->(_params, options) {
          session_calls << {
            idempotency_key: options.fetch(:idempotency_key),
            transaction_open: ActiveRecord::Base.connection.transaction_open?
          }
          release_sessions.pop
          checkout_session_factory.call(id: "cs_concurrent_checkout")
        }
      ) do
        threads_and_results = 2.times.map { run_in_thread { create_checkout } }
        calls = 2.times.map { Timeout.timeout(5) { session_calls.pop } }
        2.times { release_sessions << true }

        threads_and_results.each do |thread, result|
          assert thread.join(5), "concurrent Checkout request deadlocked"
          session = assert_thread_succeeded(result)
          assert_equal "cs_concurrent_checkout", session.id
        end

        assert_equal 1, calls.map { |call| call.fetch(:idempotency_key) }.uniq.length
        assert_equal [ false ], calls.map { |call| call.fetch(:transaction_open) }.uniq
      ensure
        2.times { release_sessions << true }
        threads_and_results&.each { |thread, _result| thread.join(1) }
      end

      assert_equal 1, @account.billing_checkout_attempts.count
      assert_equal 1, @account.billing_checkout_attempts.active.count
      assert_equal "open", @account.billing_checkout_attempts.first.status
    end

    test "subscription lifecycle synchronization shares the Account lock protocol" do
      attempt = create_attempt(customer_id: "cus_lock_lifecycle", session_id: "cs_lock_lifecycle")
      retrieve_started = Queue.new
      release_retrieve = Queue.new
      checkout_session_factory = method(:checkout_session)

      with_stripe_methods(
        customer_create: ->(*) { raise "Stripe Customer creation was unexpected" },
        session_create: ->(*) { raise "Stripe Session creation was unexpected" },
        session_retrieve: ->(*) {
          retrieve_started << true
          release_retrieve.pop
          checkout_session_factory.call(id: attempt.stripe_checkout_session_id)
        }
      ) do
        creator_thread, creator_result = run_in_thread { create_checkout }
        Timeout.timeout(5) { retrieve_started.pop }

        webhook_thread, webhook_result = run_in_thread do
          StripeSubscriptionSynchronizer.call(subscription_event(attempt))
        end
        assert webhook_thread.join(5), "subscription webhook deadlocked behind Checkout"
        assert_thread_succeeded(webhook_result)

        release_retrieve << true
        assert creator_thread.join(5), "Checkout did not resume after subscription synchronization"
        error = assert_thread_failed(creator_result)

        assert_instance_of StripeCheckoutSessionCreator::InvalidAccountError, error
      ensure
        release_retrieve << true if creator_thread&.alive?
        creator_thread&.join(1)
      end

      assert_equal "completed", attempt.reload.status
      assert_equal "sub_lock_lifecycle", @account.subscription.reload.external_subscription_id
      assert_equal "trialing", @account.subscription.status
      assert_equal 0, @account.billing_checkout_attempts.active.count
    end

    private

    def create_attempt(customer_id:, session_id:)
      BillingCheckoutAttempt.create!(
        account: @account,
        option_key: "self_managed_monthly",
        stripe_customer_id: customer_id,
        stripe_checkout_session_id: session_id,
        idempotency_key: SecureRandom.uuid,
        status: "open"
      )
    end

    def create_checkout
      StripeCheckoutSessionCreator.call(
        account: Account.find(@account.id),
        option_key: "self_managed_monthly",
        success_url: "https://app.example.test/billing/checkout/success",
        cancel_url: "https://app.example.test/billing/checkout/cancel"
      )
    end

    def checkout_session(id:, status: "open")
      Stripe::Checkout::Session.construct_from(
        id: id,
        status: status,
        url: "https://checkout.stripe.com/c/pay/#{id}"
      )
    end

    def completed_checkout_session(attempt)
      account_reference = StripeAccountReference.generate(@account)

      Stripe::Checkout::Session.construct_from(
        id: attempt.stripe_checkout_session_id,
        mode: "subscription",
        customer: attempt.stripe_customer_id,
        subscription: "sub_lock_webhook",
        client_reference_id: account_reference,
        metadata: {
          StripeCheckoutSessionCreator::ACCOUNT_REFERENCE_KEY => account_reference,
          StripeCheckoutSessionCreator::ATTEMPT_REFERENCE_KEY =>
            StripeCheckoutAttemptReference.generate(attempt),
          StripeCheckoutSessionCreator::OPTION_KEY => attempt.option_key
        }
      )
    end

    def subscription_event(attempt)
      account_reference = StripeAccountReference.generate(@account)

      Stripe::Event.construct_from(
        id: "evt_lock_lifecycle",
        type: "customer.subscription.created",
        created: Time.current.to_i,
        data: {
          object: {
            id: "sub_lock_lifecycle",
            customer: attempt.stripe_customer_id,
            status: "trialing",
            trial_end: 7.days.from_now.to_i,
            cancel_at_period_end: false,
            canceled_at: nil,
            metadata: {
              StripeCheckoutSessionCreator::ACCOUNT_REFERENCE_KEY => account_reference,
              StripeCheckoutSessionCreator::ATTEMPT_REFERENCE_KEY =>
                StripeCheckoutAttemptReference.generate(attempt),
              StripeCheckoutSessionCreator::OPTION_KEY => attempt.option_key
            },
            items: {
              data: [
                {
                  price: { id: MONTHLY_PRICE_ID },
                  current_period_end: 1.month.from_now.to_i
                }
              ]
            }
          }
        }
      )
    end

    def run_in_thread
      result = Queue.new
      thread = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          result << [ :success, yield ]
        rescue StandardError => error
          result << [ :error, error ]
        end
      end

      [ thread, result ]
    end

    def assert_thread_succeeded(result)
      status, value = result.pop
      assert_equal :success, status, value.respond_to?(:full_message) ? value.full_message : value.inspect
      value
    end

    def assert_thread_failed(result)
      status, value = result.pop
      assert_equal :error, status
      value
    end

    def with_stripe_methods(customer_create:, session_create:, session_retrieve: nil, session_expire: nil)
      session_retrieve ||= ->(*) { raise "Stripe Session retrieve was unexpected" }
      session_expire ||= ->(*) { raise "Stripe Session expiration was unexpected" }

      with_singleton_method(Stripe::Customer, :create, customer_create) do
        with_singleton_method(Stripe::Checkout::Session, :create, session_create) do
          with_singleton_method(Stripe::Checkout::Session, :retrieve, session_retrieve) do
            with_singleton_method(Stripe::Checkout::Session, :expire, session_expire) { yield }
          end
        end
      end
    end

    def with_singleton_method(receiver, method_name, replacement)
      original_method = receiver.method(method_name)
      receiver.define_singleton_method(method_name, replacement)
      yield
    ensure
      receiver.define_singleton_method(method_name, original_method)
    end
  end
end
