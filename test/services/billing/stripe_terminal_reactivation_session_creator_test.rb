require "test_helper"

module Billing
  class StripeTerminalReactivationSessionCreatorTest < ActiveSupport::TestCase
    SECRET_KEY = "sk_test_reactivation"
    MONTHLY_PRICE_ID = "price_reactivation_monthly"
    ANNUAL_PRICE_ID = "price_reactivation_annual"
    OLD_SUBSCRIPTION_ID = "sub_reactivation_terminal"
    CUSTOMER_ID = "cus_reactivation_existing"

    setup do
      @now = Time.zone.local(2026, 8, 28, 12)
      @ended_at = @now - 2.days
      @account = create_account(name: "Terminal Reactivation Owner")
      @historical_attempt = create_attempt(status: "completed")
      configure_terminal_subscription

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
      Rails.configuration.x.stripe.secret_key = @previous_secret_key
      Rails.configuration.x.stripe.livemode = @previous_livemode
      Rails.configuration.x.stripe.self_managed_monthly_price_id = @previous_monthly_price_id
      Rails.configuration.x.stripe.self_managed_annual_price_id = @previous_annual_price_id
    end

    test "creates a no-trial replacement Checkout for the existing Customer and local identities" do
      checkout_request = nil
      original_account_id = @account.id
      original_subscription_id = @account.subscription.id
      original_counts = [ Account.count, Subscription.count ]

      travel_to @now do
        with_stripe_methods(
          subscription_retrieve: ->(*) { canonical_subscription },
          session_create: ->(params, options) {
            checkout_request = [ params, options ]
            checkout_session("cs_reactivation_monthly")
          }
        ) do
          assert_equal "cs_reactivation_monthly", create_reactivation("self_managed_monthly").id
        end
      end

      params, options = checkout_request
      attempt = @account.billing_checkout_attempts.find_by!(stripe_checkout_session_id: "cs_reactivation_monthly")
      assert_equal "subscription", params.fetch(:mode)
      assert_equal CUSTOMER_ID, params.fetch(:customer)
      assert_equal MONTHLY_PRICE_ID, params.dig(:line_items, 0, :price)
      assert_not params.fetch(:subscription_data).key?(:trial_period_days)
      assert_equal attempt,
        StripeCheckoutAttemptReference.find!(
          params.dig(:subscription_data, :metadata, StripeCheckoutSessionCreator::ATTEMPT_REFERENCE_KEY)
        )
      assert attempt.reactivation?
      assert_equal OLD_SUBSCRIPTION_ID, attempt.replaces_external_subscription_id
      assert_equal SECRET_KEY, options.fetch(:api_key)
      assert_equal original_account_id, @account.reload.id
      assert_equal original_subscription_id, @account.subscription.reload.id
      assert_equal CUSTOMER_ID, @account.subscription.external_customer_id
      assert_equal OLD_SUBSCRIPTION_ID, @account.subscription.external_subscription_id
      assert_equal "canceled", @account.subscription.status
      assert_equal original_counts, [ Account.count, Subscription.count ]
    end

    test "uses only server-selected monthly and annual Prices without a new trial" do
      requests = []

      travel_to @now do
        %w[self_managed_monthly self_managed_annual].each_with_index do |option_key, index|
          @account.billing_checkout_attempts.active.update_all(status: "expired")

          with_stripe_methods(
            subscription_retrieve: ->(*) { canonical_subscription },
            session_create: ->(params, _options) {
              requests << params
              checkout_session("cs_reactivation_option_#{index}")
            }
          ) do
            create_reactivation(option_key)
          end
        end
      end

      assert_equal [ MONTHLY_PRICE_ID, ANNUAL_PRICE_ID ], requests.map { |params| params.dig(:line_items, 0, :price) }
      requests.each do |params|
        assert_not params.fetch(:subscription_data).key?(:trial_period_days)
      end
    end

    test "same-option retry reuses one replacement attempt and Checkout Session" do
      create_calls = 0
      retrieve_calls = 0

      travel_to @now do
        with_stripe_methods(
          subscription_retrieve: ->(*) { canonical_subscription },
          session_create: ->(*) {
            create_calls += 1
            checkout_session("cs_reactivation_retry")
          },
          session_retrieve: ->(*) {
            retrieve_calls += 1
            checkout_session("cs_reactivation_retry")
          }
        ) do
          first = create_reactivation("self_managed_monthly")
          second = create_reactivation("self_managed_monthly")

          assert_equal first.id, second.id
        end
      end

      assert_equal 1, create_calls
      assert_equal 1, retrieve_calls
      assert_equal 1, @account.billing_checkout_attempts.active.count
      assert_equal 1, @account.billing_checkout_attempts.where.not(replaces_external_subscription_id: nil).count
    end

    test "ambiguous Checkout failure retains one replacement attempt and idempotency key" do
      create_calls = 0
      idempotency_keys = []

      travel_to @now do
        with_stripe_methods(
          subscription_retrieve: ->(*) { canonical_subscription },
          session_create: ->(_params, options) {
            create_calls += 1
            idempotency_keys << options.fetch(:idempotency_key)
            raise Stripe::APIConnectionError, "private ambiguous result" if create_calls == 1

            checkout_session("cs_reactivation_ambiguous")
          }
        ) do
          assert_raises(StripeTerminalReactivationSessionCreator::ReactivationError) do
            create_reactivation("self_managed_monthly")
          end
          assert_equal "cs_reactivation_ambiguous", create_reactivation("self_managed_monthly").id
        end
      end

      assert_equal 2, create_calls
      assert_equal 1, idempotency_keys.uniq.length
      assert_equal 1, @account.billing_checkout_attempts.where.not(replaces_external_subscription_id: nil).count
    end

    test "refuses every nonterminal and unsupported canonical status despite elapsed local dates" do
      statuses = %w[active trialing past_due unpaid paused incomplete incomplete_expired future_status]

      travel_to @now do
        statuses.each do |status|
          with_stripe_methods(
            subscription_retrieve: ->(*) { canonical_subscription(status:) },
            session_create: ->(*) { flunk("nonterminal evidence must not create Checkout") }
          ) do
            assert_raises(StripeTerminalReactivationSessionCreator::ReactivationError) do
              create_reactivation("self_managed_monthly")
            end
          end
        end
      end

      assert_equal 0, @account.billing_checkout_attempts.where.not(replaces_external_subscription_id: nil).count
      assert_equal OLD_SUBSCRIPTION_ID, @account.subscription.reload.external_subscription_id
    end

    test "refuses missing contradictory and unverifiable local evidence before canonical retrieval" do
      invalid_updates = [
        { provider: "local" },
        { provider: "stripe", plan: "professional" },
        { plan: "self_managed", status: "active" },
        { status: "canceled", entitlement_ended_at: nil },
        { entitlement_ended_at: @ended_at, last_synced_at: nil }
      ]

      travel_to @now do
        invalid_updates.each do |attributes|
          configure_terminal_subscription
          @account.subscription.update!(attributes)

          with_stripe_methods(
            subscription_retrieve: ->(*) { flunk("invalid local evidence must not retrieve Stripe") },
            session_create: ->(*) { flunk("invalid local evidence must not create Checkout") }
          ) do
            assert_raises(StripeTerminalReactivationSessionCreator::ReactivationError) do
              create_reactivation("self_managed_monthly")
            end
          end
        end
      end
    end

    test "Account deactivation during canonical verification prevents Checkout creation" do
      travel_to @now do
        with_stripe_methods(
          subscription_retrieve: ->(*) {
            @account.update!(active: false)
            canonical_subscription
          },
          session_create: ->(*) { flunk("an inactive Account must not create Checkout") }
        ) do
          assert_raises(StripeTerminalReactivationSessionCreator::ReactivationError) do
            create_reactivation("self_managed_monthly")
          end
        end
      end

      assert_equal 0, @account.billing_checkout_attempts.where.not(replaces_external_subscription_id: nil).count
      assert_equal OLD_SUBSCRIPTION_ID, @account.subscription.reload.external_subscription_id
    end

    test "refuses canonical Customer Price mode ending and signed-reference mismatches" do
      invalid_subscriptions = [
        canonical_subscription(customer: "cus_other"),
        canonical_subscription(price_id: "price_unknown"),
        canonical_subscription(livemode: true),
        canonical_subscription(ended_at: @ended_at - 1.hour),
        canonical_subscription(account_reference: "tampered"),
        canonical_subscription(attempt_reference: "tampered")
      ]

      travel_to @now do
        invalid_subscriptions.each do |remote_subscription|
          with_stripe_methods(
            subscription_retrieve: ->(*) { remote_subscription },
            session_create: ->(*) { flunk("contradictory canonical evidence must not create Checkout") }
          ) do
            assert_raises(StripeTerminalReactivationSessionCreator::ReactivationError) do
              create_reactivation("self_managed_monthly")
            end
          end
        end
      end
    end

    test "Stripe failure logs only its class and preserves terminal state" do
      original_state = subscription_state
      log_output = capture_rails_logs do
        travel_to @now do
          with_stripe_methods(
            subscription_retrieve: ->(*) { raise Stripe::APIConnectionError, "private provider detail" },
            session_create: ->(*) { flunk("failed verification must not create Checkout") }
          ) do
            assert_raises(StripeTerminalReactivationSessionCreator::ReactivationError) do
              create_reactivation("self_managed_monthly")
            end
          end
        end
      end

      assert_includes log_output, "Stripe::APIConnectionError"
      assert_not_includes log_output, "private provider detail"
      assert_not_includes log_output, SECRET_KEY
      assert_equal original_state, subscription_state
    end

    private

    def configure_terminal_subscription
      @account.subscription.update!(
        provider: "stripe",
        plan: "self_managed",
        status: "canceled",
        external_customer_id: CUSTOMER_ID,
        external_subscription_id: OLD_SUBSCRIPTION_ID,
        current_period_ends_at: @ended_at,
        cancel_at_period_end: false,
        canceled_at: @ended_at,
        entitlement_ended_at: @ended_at,
        last_synced_at: @ended_at
      )
    end

    def canonical_subscription(status: "canceled", customer: CUSTOMER_ID, price_id: MONTHLY_PRICE_ID,
      livemode: false, ended_at: @ended_at,
      account_reference: StripeAccountReference.generate(@account),
      attempt_reference: StripeCheckoutAttemptReference.generate(@historical_attempt))
      Stripe::Subscription.construct_from(
        id: OLD_SUBSCRIPTION_ID,
        customer:,
        livemode:,
        status:,
        ended_at: ended_at.to_i,
        metadata: {
          StripeCheckoutSessionCreator::ACCOUNT_REFERENCE_KEY => account_reference,
          StripeCheckoutSessionCreator::ATTEMPT_REFERENCE_KEY => attempt_reference,
          StripeCheckoutSessionCreator::OPTION_KEY => "self_managed_monthly"
        },
        items: { data: [ { price: { id: price_id } } ] }
      )
    end

    def create_reactivation(option_key)
      StripeTerminalReactivationSessionCreator.call(
        account: @account,
        option_key:,
        success_url: "https://app.example.test/billing/checkout/success",
        cancel_url: "https://app.example.test/billing/checkout/cancel"
      )
    end

    def checkout_session(id)
      Stripe::Checkout::Session.construct_from(
        id:,
        status: "open",
        url: "https://checkout.stripe.com/c/pay/#{id}"
      )
    end

    def create_attempt(status:, customer_id: CUSTOMER_ID, option_key: "self_managed_monthly")
      BillingCheckoutAttempt.create!(
        account: @account,
        option_key:,
        stripe_customer_id: customer_id,
        stripe_checkout_session_id: "cs_historical_#{SecureRandom.hex(4)}",
        idempotency_key: SecureRandom.uuid,
        status:
      )
    end

    def with_stripe_methods(subscription_retrieve:, session_create:, session_retrieve: nil)
      session_retrieve ||= ->(*) { flunk("Stripe Checkout retrieve was unexpected") }
      with_singleton_method(Stripe::Subscription, :retrieve, subscription_retrieve) do
        with_singleton_method(Stripe::Customer, :create, ->(*) { flunk("reactivation must reuse its Customer") }) do
          with_singleton_method(Stripe::Checkout::Session, :create, session_create) do
            with_singleton_method(Stripe::Checkout::Session, :retrieve, session_retrieve) do
              yield
            end
          end
        end
      end
    end

    def with_singleton_method(receiver, method_name, replacement)
      original = receiver.method(method_name)
      receiver.define_singleton_method(method_name) do |*args, **kwargs, &block|
        replacement.call(*args, **kwargs, &block)
      end
      yield
    ensure
      receiver.define_singleton_method(method_name, original)
    end

    def subscription_state
      @account.subscription.reload.attributes.except("created_at", "updated_at")
    end

    def capture_rails_logs
      previous_logger = Rails.logger
      output = StringIO.new
      Rails.logger = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(output))
      yield
      output.string
    ensure
      Rails.logger = previous_logger
    end
  end
end
