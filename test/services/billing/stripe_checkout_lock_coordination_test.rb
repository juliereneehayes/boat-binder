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
      @previous_livemode = Rails.configuration.x.stripe.livemode
      @previous_monthly_price_id = Rails.configuration.x.stripe.self_managed_monthly_price_id
      @previous_annual_price_id = Rails.configuration.x.stripe.self_managed_annual_price_id
      Rails.configuration.x.stripe.secret_key = SECRET_KEY
      Rails.configuration.x.stripe.livemode = false
      Rails.configuration.x.stripe.self_managed_monthly_price_id = MONTHLY_PRICE_ID
      Rails.configuration.x.stripe.self_managed_annual_price_id = ANNUAL_PRICE_ID
    end

    teardown do
      @account&.destroy!
      Rails.configuration.x.stripe.secret_key = @previous_secret_key
      Rails.configuration.x.stripe.livemode = @previous_livemode
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

    test "concurrent terminal reactivation requests serialize and reuse one no-trial Session" do
      historical_attempt, ended_at = configure_terminal_reactivation
      canonical_subscription = terminal_subscription(historical_attempt, ended_at:)
      retrieval_count = 0
      retrieval_mutex = Mutex.new
      retrievals_started = Queue.new
      release_first_retrieval = Queue.new
      second_worker_started = Queue.new
      session_creates = Queue.new
      session_retrieves = Queue.new
      checkout_session_factory = method(:checkout_session)

      with_stripe_methods(
        customer_create: ->(*) { raise "reactivation must reuse its Stripe Customer" },
        session_create: ->(params, options) {
          session_creates << [ params, options ]
          checkout_session_factory.call(id: "cs_concurrent_reactivation")
        },
        session_retrieve: ->(*) {
          session_retrieves << true
          checkout_session_factory.call(id: "cs_concurrent_reactivation")
        },
        subscription_retrieve: ->(*) {
          retrieval_number = retrieval_mutex.synchronize do
            retrieval_count += 1
          end
          retrievals_started << retrieval_number
          release_first_retrieval.pop if retrieval_number == 1
          canonical_subscription
        }
      ) do
        first_thread, first_result = run_in_thread { create_terminal_reactivation }
        assert_equal 1, Timeout.timeout(5) { retrievals_started.pop }

        second_thread, second_result = run_in_thread do
          second_worker_started << true
          create_terminal_reactivation
        end
        Timeout.timeout(5) { second_worker_started.pop }
        assert_raises(Timeout::Error) { Timeout.timeout(0.2) { retrievals_started.pop } }

        release_first_retrieval << true
        assert first_thread.join(5),
          "nested advisory and row-lock reactivation path self-deadlocked"
        first_session = assert_thread_succeeded(first_result)
        assert_equal 2, Timeout.timeout(5) { retrievals_started.pop }
        assert second_thread.join(5), "second reactivation request did not finish"
        second_session = assert_thread_succeeded(second_result)

        assert_equal "cs_concurrent_reactivation", first_session.id
        assert_equal first_session.id, second_session.id
      ensure
        release_first_retrieval << true if first_thread&.alive?
        first_thread&.join(1)
        second_thread&.join(1)
      end

      create_params, = session_creates.pop
      assert session_creates.empty?, "concurrent reactivation must create only one Stripe Session"
      assert_equal 1, session_retrieves.length
      assert_not create_params.fetch(:subscription_data).key?(:trial_period_days)
      assert_equal 1, @account.billing_checkout_attempts.active.count
      assert_equal 1, @account.billing_checkout_attempts.where.not(replaces_external_subscription_id: nil).count
      assert_equal "sub_terminal_reactivation", @account.subscription.reload.external_subscription_id
    end

    test "subscription lifecycle synchronization shares the Account lock protocol" do
      attempt = create_attempt(customer_id: "cus_lock_lifecycle", session_id: "cs_lock_lifecycle")
      event = subscription_event(attempt)
      retrieve_started = Queue.new
      release_retrieve = Queue.new
      subscription_network_transaction_state = Queue.new
      checkout_session_factory = method(:checkout_session)

      with_stripe_methods(
        customer_create: ->(*) { raise "Stripe Customer creation was unexpected" },
        session_create: ->(*) { raise "Stripe Session creation was unexpected" },
        session_retrieve: ->(*) {
          retrieve_started << true
          release_retrieve.pop
          checkout_session_factory.call(id: attempt.stripe_checkout_session_id)
        },
        subscription_retrieve: ->(*) {
          subscription_network_transaction_state << ActiveRecord::Base.connection.transaction_open?
          event.data.object
        }
      ) do
        creator_thread, creator_result = run_in_thread { create_checkout }
        Timeout.timeout(5) { retrieve_started.pop }

        webhook_thread, webhook_result = run_in_thread do
          StripeSubscriptionSynchronizer.call(event)
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
      assert_equal false, subscription_network_transaction_state.pop
    end

    test "lifecycle synchronization revalidates local association after Stripe retrieval" do
      attempt = create_attempt(customer_id: "cus_revalidate_lifecycle", session_id: "cs_revalidate_lifecycle")
      event = subscription_event(attempt, subscription_id: "sub_revalidate_lifecycle")
      retrieval_started = Queue.new
      release_retrieval = Queue.new

      with_stripe_methods(
        customer_create: ->(*) { raise "Stripe Customer creation was unexpected" },
        session_create: ->(*) { raise "Stripe Session creation was unexpected" },
        subscription_retrieve: ->(*) {
          retrieval_started << true
          release_retrieval.pop
          event.data.object
        }
      ) do
        webhook_thread, webhook_result = run_in_thread do
          StripeSubscriptionSynchronizer.call(event)
        end
        Timeout.timeout(5) { retrieval_started.pop }

        @account.subscription.update!(
          provider: "stripe",
          external_customer_id: "cus_revalidate_lifecycle",
          external_subscription_id: "sub_newer_local_association"
        )
        release_retrieval << true

        assert webhook_thread.join(5), "lifecycle synchronization did not resume"
        error = assert_thread_failed(webhook_result)
        assert_instance_of StripeWebhookAssociationError, error
        assert_equal "subscription_mismatch", error.code
      ensure
        release_retrieval << true if webhook_thread&.alive?
        webhook_thread&.join(1)
      end

      subscription = @account.subscription.reload
      assert_equal "sub_newer_local_association", subscription.external_subscription_id
      assert_equal "open", attempt.reload.status
    end

    test "distinct lifecycle events serialize canonical retrieval and commit for the same Account" do
      attempt = create_attempt(customer_id: "cus_serial_lifecycle", session_id: "cs_serial_lifecycle")
      first_event = subscription_event(attempt, event_id: "evt_serial_first", status: "trialing")
      second_event = subscription_event(attempt, event_id: "evt_serial_second", status: "active")
      first_retrieval_started = Queue.new
      second_worker_started = Queue.new
      second_retrieval_started = Queue.new
      release_first_retrieval = Queue.new
      canonical_factory = method(:canonical_subscription)

      with_stripe_methods(
        customer_create: ->(*) { raise "Stripe Customer creation was unexpected" },
        session_create: ->(*) { raise "Stripe Session creation was unexpected" },
        subscription_retrieve: ->(*) {
          if Thread.current[:canonical_status] == "trialing"
            first_retrieval_started << true
            release_first_retrieval.pop
          else
            second_retrieval_started << true
          end
          canonical_factory.call(attempt, status: Thread.current[:canonical_status])
        }
      ) do
        first_thread, first_result = run_in_thread do
          Thread.current[:canonical_status] = "trialing"
          StripeSubscriptionSynchronizer.call(first_event)
        end
        Timeout.timeout(5) { first_retrieval_started.pop }

        second_thread, second_result = run_in_thread do
          Thread.current[:canonical_status] = "active"
          second_worker_started << true
          StripeSubscriptionSynchronizer.call(second_event)
        end
        Timeout.timeout(5) { second_worker_started.pop }
        assert_raises(Timeout::Error) { Timeout.timeout(0.2) { second_retrieval_started.pop } }

        release_first_retrieval << true
        assert first_thread.join(5), "first lifecycle synchronization did not finish"
        assert_thread_succeeded(first_result)
        Timeout.timeout(5) { second_retrieval_started.pop }
        assert second_thread.join(5), "second lifecycle synchronization did not finish"
        assert_thread_succeeded(second_result)
      ensure
        release_first_retrieval << true if first_thread&.alive?
        first_thread&.join(1)
        second_thread&.join(1)
      end

      assert_equal "active", @account.subscription.reload.status
      assert_equal "completed", attempt.reload.status
    end

    test "different Accounts retrieve canonical subscriptions concurrently" do
      other_account = create_account(name: "Checkout Locking Other #{SecureRandom.hex(6)}")
      first_attempt = create_attempt(customer_id: "cus_parallel_first", session_id: "cs_parallel_first")
      second_attempt = create_attempt_for(
        other_account,
        customer_id: "cus_parallel_second",
        session_id: "cs_parallel_second"
      )
      first_event = subscription_event(
        first_attempt,
        event_id: "evt_parallel_first",
        subscription_id: "sub_parallel_first"
      )
      second_event = subscription_event(
        second_attempt,
        account: other_account,
        event_id: "evt_parallel_second",
        subscription_id: "sub_parallel_second"
      )
      retrievals_started = Queue.new
      release_retrievals = Queue.new
      canonical_factory = method(:canonical_subscription)

      with_stripe_methods(
        customer_create: ->(*) { raise "Stripe Customer creation was unexpected" },
        session_create: ->(*) { raise "Stripe Session creation was unexpected" },
        subscription_retrieve: ->(*) {
          retrievals_started << true
          release_retrievals.pop
          canonical_factory.call(
            Thread.current[:attempt],
            account: Thread.current[:account],
            subscription_id: Thread.current[:subscription_id],
            status: "active"
          )
        }
      ) do
        first_thread, first_result = run_in_thread do
          Thread.current[:attempt] = first_attempt
          Thread.current[:account] = @account
          Thread.current[:subscription_id] = "sub_parallel_first"
          StripeSubscriptionSynchronizer.call(first_event)
        end
        second_thread, second_result = run_in_thread do
          Thread.current[:attempt] = second_attempt
          Thread.current[:account] = other_account
          Thread.current[:subscription_id] = "sub_parallel_second"
          StripeSubscriptionSynchronizer.call(second_event)
        end

        2.times { Timeout.timeout(5) { retrievals_started.pop } }
        2.times { release_retrievals << true }
        assert first_thread.join(5), "first Account reconciliation did not finish"
        assert second_thread.join(5), "second Account reconciliation did not finish"
        assert_thread_succeeded(first_result)
        assert_thread_succeeded(second_result)
      ensure
        2.times { release_retrievals << true }
        first_thread&.join(1)
        second_thread&.join(1)
      end

      assert_equal "active", @account.subscription.reload.status
      assert_equal "active", other_account.subscription.reload.status
    ensure
      other_account&.destroy!
    end

    test "lifecycle reconciliation lock is released after Stripe retrieval failure" do
      attempt = create_attempt(customer_id: "cus_failure_release", session_id: "cs_failure_release")
      event = subscription_event(attempt, event_id: "evt_failure_release")
      calls = 0
      canonical_factory = method(:canonical_subscription)

      with_stripe_methods(
        customer_create: ->(*) { raise "Stripe Customer creation was unexpected" },
        session_create: ->(*) { raise "Stripe Session creation was unexpected" },
        subscription_retrieve: ->(*) {
          calls += 1
          raise Stripe::APIConnectionError, "controlled connection failure" if calls == 1

          canonical_factory.call(attempt, status: "active")
        }
      ) do
        assert_raises(Stripe::APIConnectionError) { StripeSubscriptionSynchronizer.call(event) }
        assert_nothing_raised { StripeSubscriptionSynchronizer.call(event) }
      end

      assert_equal 2, calls
      assert_equal "active", @account.subscription.reload.status
    end

    test "lifecycle reconciliation lock is released after commit validation failure" do
      attempt = create_attempt(customer_id: "cus_validation_release", session_id: "cs_validation_release")
      event = subscription_event(attempt, event_id: "evt_validation_release")
      canonical_subscriptions = Queue.new
      canonical_factory = method(:canonical_subscription)
      invalid_subscription = canonical_factory.call(attempt, status: "active")
      invalid_subscription.items.data.first.current_period_end = "invalid"
      canonical_subscriptions << invalid_subscription
      canonical_subscriptions << canonical_factory.call(attempt, status: "active")

      with_stripe_methods(
        customer_create: ->(*) { raise "Stripe Customer creation was unexpected" },
        session_create: ->(*) { raise "Stripe Session creation was unexpected" },
        subscription_retrieve: ->(*) { canonical_subscriptions.pop }
      ) do
        error = assert_raises(StripeWebhookAssociationError) { StripeSubscriptionSynchronizer.call(event) }
        assert_equal "invalid_timestamp", error.code
        assert_nothing_raised { StripeSubscriptionSynchronizer.call(event) }
      end

      assert_equal "active", @account.subscription.reload.status
    end

    test "racing monthly and annual requests cannot return the wrong Price" do
      session_started = Queue.new
      release_session = Queue.new
      requested_prices = Queue.new
      checkout_session_factory = method(:checkout_session)

      with_stripe_methods(
        customer_create: ->(*) { Stripe::Customer.construct_from(id: "cus_option_race") },
        session_create: ->(params, _options) {
          requested_prices << params.dig(:line_items, 0, :price)
          session_started << true
          release_session.pop
          checkout_session_factory.call(id: "cs_option_race")
        }
      ) do
        monthly_thread, monthly_result = run_in_thread do
          create_checkout(option_key: "self_managed_monthly")
        end
        Timeout.timeout(5) { session_started.pop }

        annual_thread, annual_result = run_in_thread do
          create_checkout(option_key: "self_managed_annual")
        end
        assert annual_thread.join(5), "annual request waited on the monthly Stripe call"
        annual_error = assert_thread_failed(annual_result)
        assert_instance_of StripeCheckoutSessionCreator::InvalidOptionError, annual_error

        release_session << true
        assert monthly_thread.join(5), "monthly Checkout did not finish"
        monthly_session = assert_thread_succeeded(monthly_result)
        assert_equal "cs_option_race", monthly_session.id
      ensure
        release_session << true if monthly_thread&.alive?
        monthly_thread&.join(1)
        annual_thread&.join(1)
      end

      assert_equal MONTHLY_PRICE_ID, requested_prices.pop
      assert requested_prices.empty?, "the annual request must not create a Stripe Session"
      attempt = @account.billing_checkout_attempts.one? ? @account.billing_checkout_attempts.first : nil
      assert attempt
      assert_equal "self_managed_monthly", attempt.option_key
      assert_equal "open", attempt.status
    end

    private

    def create_attempt(customer_id:, session_id:)
      create_attempt_for(@account, customer_id:, session_id:)
    end

    def create_attempt_for(account, customer_id:, session_id:)
      BillingCheckoutAttempt.create!(
        account: account,
        option_key: "self_managed_monthly",
        stripe_customer_id: customer_id,
        stripe_checkout_session_id: session_id,
        idempotency_key: SecureRandom.uuid,
        status: "open"
      )
    end

    def create_checkout(option_key: "self_managed_monthly")
      StripeCheckoutSessionCreator.call(
        account: Account.find(@account.id),
        option_key: option_key,
        success_url: "https://app.example.test/billing/checkout/success",
        cancel_url: "https://app.example.test/billing/checkout/cancel"
      )
    end

    def create_terminal_reactivation
      StripeTerminalReactivationSessionCreator.call(
        account: Account.find(@account.id),
        option_key: "self_managed_monthly",
        success_url: "https://app.example.test/billing/checkout/success",
        cancel_url: "https://app.example.test/billing/checkout/cancel"
      )
    end

    def configure_terminal_reactivation
      ended_at = 2.days.ago.change(usec: 0)
      attempt = BillingCheckoutAttempt.create!(
        account: @account,
        option_key: "self_managed_monthly",
        stripe_customer_id: "cus_terminal_reactivation",
        stripe_checkout_session_id: "cs_terminal_historical",
        idempotency_key: SecureRandom.uuid,
        status: "completed"
      )
      @account.subscription.update!(
        provider: "stripe",
        plan: "self_managed",
        status: "canceled",
        external_customer_id: attempt.stripe_customer_id,
        external_subscription_id: "sub_terminal_reactivation",
        current_period_ends_at: ended_at,
        canceled_at: ended_at,
        entitlement_ended_at: ended_at,
        last_synced_at: ended_at
      )

      [ attempt, ended_at ]
    end

    def terminal_subscription(attempt, ended_at:)
      account_reference = StripeAccountReference.generate(@account)

      Stripe::Subscription.construct_from(
        id: "sub_terminal_reactivation",
        customer: attempt.stripe_customer_id,
        livemode: false,
        status: "canceled",
        ended_at: ended_at.to_i,
        metadata: {
          StripeCheckoutSessionCreator::ACCOUNT_REFERENCE_KEY => account_reference,
          StripeCheckoutSessionCreator::ATTEMPT_REFERENCE_KEY =>
            StripeCheckoutAttemptReference.generate(attempt),
          StripeCheckoutSessionCreator::OPTION_KEY => attempt.option_key
        },
        items: { data: [ { price: { id: MONTHLY_PRICE_ID } } ] }
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

    def subscription_event(attempt, account: @account, subscription_id: "sub_lock_lifecycle",
      event_id: "evt_lock_lifecycle", status: "trialing")
      account_reference = StripeAccountReference.generate(account)

      Stripe::Event.construct_from(
        id: event_id,
        type: "customer.subscription.created",
        created: Time.current.to_i,
        data: {
          object: {
            id: subscription_id,
            customer: attempt.stripe_customer_id,
            status: status,
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

    def canonical_subscription(attempt, account: @account, subscription_id: "sub_lock_lifecycle", status: "trialing")
      subscription_event(
        attempt,
        account:,
        subscription_id:,
        status:
      ).data.object
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

    def with_stripe_methods(customer_create:, session_create:, session_retrieve: nil, session_expire: nil,
      subscription_retrieve: nil)
      session_retrieve ||= ->(*) { raise "Stripe Session retrieve was unexpected" }
      session_expire ||= ->(*) { raise "Stripe Session expiration was unexpected" }
      subscription_retrieve ||= ->(*) { raise "Stripe Subscription retrieve was unexpected" }

      with_singleton_method(Stripe::Customer, :create, customer_create) do
        with_singleton_method(Stripe::Checkout::Session, :create, session_create) do
          with_singleton_method(Stripe::Checkout::Session, :retrieve, session_retrieve) do
            with_singleton_method(Stripe::Checkout::Session, :expire, session_expire) do
              with_singleton_method(Stripe::Subscription, :retrieve, subscription_retrieve) { yield }
            end
          end
        end
      end
    end

    def with_singleton_method(receiver, method_name, replacement)
      original_method = receiver.method(method_name)
      receiver.define_singleton_method(method_name) do |*args, **kwargs, &block|
        replacement.call(*args, **kwargs, &block)
      end
      yield
    ensure
      receiver.define_singleton_method(method_name, original_method)
    end
  end
end
