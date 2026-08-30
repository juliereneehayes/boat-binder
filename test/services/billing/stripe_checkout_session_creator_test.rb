require "test_helper"

module Billing
  class StripeCheckoutSessionCreatorTest < ActiveSupport::TestCase
    SECRET_KEY = "sk_test_checkout"
    MONTHLY_PRICE_ID = "price_checkout_monthly"
    ANNUAL_PRICE_ID = "price_checkout_annual"
    CHECKOUT_SESSION = lambda do |id:, status: "open"|
      Stripe::Checkout::Session.construct_from(
        id: id,
        status: status,
        url: "https://checkout.stripe.com/c/pay/#{id}"
      )
    end

    setup do
      @account = create_account(name: "Checkout Service Owner")
      @previous_secret_key = Rails.configuration.x.stripe.secret_key
      @previous_monthly_price_id = Rails.configuration.x.stripe.self_managed_monthly_price_id
      @previous_annual_price_id = Rails.configuration.x.stripe.self_managed_annual_price_id
      Rails.configuration.x.stripe.secret_key = SECRET_KEY
      Rails.configuration.x.stripe.self_managed_monthly_price_id = MONTHLY_PRICE_ID
      Rails.configuration.x.stripe.self_managed_annual_price_id = ANNUAL_PRICE_ID
    end

    teardown do
      Rails.configuration.x.stripe.secret_key = @previous_secret_key
      Rails.configuration.x.stripe.self_managed_monthly_price_id = @previous_monthly_price_id
      Rails.configuration.x.stripe.self_managed_annual_price_id = @previous_annual_price_id
    end

    test "monthly Checkout stores a pending attempt without mutating the Subscription" do
      original_subscription = subscription_state(@account.subscription)
      customer_request = nil
      checkout_request = nil

      with_stripe_methods(
        customer_create: ->(params, options) {
          customer_request = [ params, options ]
          Stripe::Customer.construct_from(id: "cus_checkout_monthly")
        },
        session_create: ->(params, options) {
          checkout_request = [ params, options ]
          CHECKOUT_SESSION.call(id: "cs_monthly")
        }
      ) do
        assert_equal "cs_monthly", create_checkout(option_key: "self_managed_monthly").id
      end

      customer_params, customer_options = customer_request
      checkout_params, checkout_options = checkout_request
      attempt = @account.billing_checkout_attempts.find_by!(stripe_checkout_session_id: "cs_monthly")
      account_reference = customer_params.dig(:metadata, StripeCheckoutSessionCreator::ACCOUNT_REFERENCE_KEY)
      attempt_reference = checkout_params.dig(:metadata, StripeCheckoutSessionCreator::ATTEMPT_REFERENCE_KEY)

      assert_equal @account, StripeAccountReference.find!(account_reference)
      assert_equal attempt, StripeCheckoutAttemptReference.find!(attempt_reference)
      assert_equal SECRET_KEY, customer_options.fetch(:api_key)
      assert_match(/\Aboat-binder-customer-v1-/, customer_options.fetch(:idempotency_key))
      assert_equal "subscription", checkout_params.fetch(:mode)
      assert_equal "cus_checkout_monthly", checkout_params.fetch(:customer)
      assert_equal account_reference, checkout_params.fetch(:client_reference_id)
      assert_equal MONTHLY_PRICE_ID, checkout_params.dig(:line_items, 0, :price)
      assert_equal 7, checkout_params.dig(:subscription_data, :trial_period_days)
      assert_equal "always", checkout_params.fetch(:payment_method_collection)
      assert_equal attempt_reference,
        checkout_params.dig(:subscription_data, :metadata, StripeCheckoutSessionCreator::ATTEMPT_REFERENCE_KEY)
      assert_equal "self_managed_monthly",
        checkout_params.dig(:subscription_data, :metadata, StripeCheckoutSessionCreator::OPTION_KEY)
      assert_equal "https://app.example.test/billing/checkout/success", checkout_params.fetch(:success_url)
      assert_equal "https://app.example.test/billing/checkout/cancel", checkout_params.fetch(:cancel_url)
      assert_equal SECRET_KEY, checkout_options.fetch(:api_key)
      assert_match(/\Aboat-binder-checkout-v1-/, checkout_options.fetch(:idempotency_key))
      assert_equal "open", attempt.status
      assert_equal "cus_checkout_monthly", attempt.stripe_customer_id
      assert_equal original_subscription, subscription_state(@account.subscription.reload)
    end

    test "Checkout without a trial omits trial period days and retains subscription metadata" do
      definitions = SubscriptionPlanCatalog::DEFAULT_DEFINITIONS.map(&:deep_dup)
      definitions.find { |definition| definition.fetch(:key) == "self_managed_monthly" }[:trial_days] = 0
      catalog = SubscriptionPlanCatalog.new(
        price_ids: {
          "self_managed_monthly" => MONTHLY_PRICE_ID,
          "self_managed_annual" => ANNUAL_PRICE_ID
        },
        definitions: definitions
      )
      checkout_params = nil

      with_stripe_methods(
        customer_create: ->(*) { Stripe::Customer.construct_from(id: "cus_no_trial") },
        session_create: ->(params, _options) {
          checkout_params = params
          CHECKOUT_SESSION.call(id: "cs_no_trial")
        }
      ) do
        checkout_creator(option_key: "self_managed_monthly", catalog: catalog).call
      end

      subscription_data = checkout_params.fetch(:subscription_data)
      assert_not subscription_data.key?(:trial_period_days)
      assert_equal "self_managed_monthly",
        subscription_data.dig(:metadata, StripeCheckoutSessionCreator::OPTION_KEY)
      assert subscription_data.dig(:metadata, StripeCheckoutSessionCreator::ATTEMPT_REFERENCE_KEY).present?
    end

    test "a same-option retry reuses the existing open Checkout Session" do
      customer_calls = 0
      session_create_calls = 0
      session_retrieve_calls = 0
      retrieved_session_id = nil
      retrieve_options = nil

      with_stripe_methods(
        customer_create: ->(*) {
          customer_calls += 1
          Stripe::Customer.construct_from(id: "cus_retry")
        },
        session_create: ->(*) {
          session_create_calls += 1
          CHECKOUT_SESSION.call(id: "cs_retry")
        },
        session_retrieve: ->(session_id, options) {
          session_retrieve_calls += 1
          retrieved_session_id = session_id
          retrieve_options = options
          CHECKOUT_SESSION.call(id: "cs_retry")
        }
      ) do
        first = create_checkout(option_key: "self_managed_monthly")
        second = create_checkout(option_key: "self_managed_monthly")

        assert_equal first.id, second.id
        assert_equal first.url, second.url
      end

      assert_equal 1, customer_calls
      assert_equal 1, session_create_calls
      assert_equal 1, session_retrieve_calls
      assert_equal "cs_retry", retrieved_session_id
      assert_equal SECRET_KEY, retrieve_options.fetch(:api_key)
      assert_equal 1, @account.billing_checkout_attempts.active.count
      assert_equal 1, @account.billing_checkout_attempts.count
    end

    test "a same-option request activates its existing creating attempt" do
      attempt = create_attempt(
        customer_id: "cus_creating_monthly",
        session_id: nil,
        option_key: "self_managed_monthly",
        status: "creating"
      )
      checkout_price_ids = []

      with_stripe_methods(
        customer_create: ->(*) { flunk("the creating attempt Customer should be reused") },
        session_create: ->(params, _options) {
          checkout_price_ids << params.dig(:line_items, 0, :price)
          CHECKOUT_SESSION.call(id: "cs_creating_monthly")
        }
      ) do
        assert_equal "cs_creating_monthly", create_checkout(option_key: "self_managed_monthly").id
      end

      assert_equal [ MONTHLY_PRICE_ID ], checkout_price_ids
      assert_equal "open", attempt.reload.status
      assert_equal "self_managed_monthly", attempt.option_key
    end

    test "a monthly creating attempt cannot satisfy an annual request" do
      attempt = create_attempt(
        customer_id: "cus_monthly_blocks_annual",
        session_id: nil,
        option_key: "self_managed_monthly",
        status: "creating"
      )

      assert_no_stripe_calls do
        assert_raises(StripeCheckoutSessionCreator::InvalidOptionError) do
          create_checkout(option_key: "self_managed_annual")
        end
      end

      assert_equal "creating", attempt.reload.status
      assert_equal "self_managed_monthly", attempt.option_key
      assert_nil attempt.stripe_checkout_session_id
    end

    test "an annual creating attempt cannot satisfy a monthly request" do
      attempt = create_attempt(
        customer_id: "cus_annual_blocks_monthly",
        session_id: nil,
        option_key: "self_managed_annual",
        status: "creating"
      )

      assert_no_stripe_calls do
        assert_raises(StripeCheckoutSessionCreator::InvalidOptionError) do
          create_checkout(option_key: "self_managed_monthly")
        end
      end

      assert_equal "creating", attempt.reload.status
      assert_equal "self_managed_annual", attempt.option_key
      assert_nil attempt.stripe_checkout_session_id
    end

    test "changing options expires the open Session before creating its replacement" do
      created_session_ids = %w[cs_monthly_old cs_annual_new]
      expired_session_ids = []

      with_stripe_methods(
        customer_create: ->(*) { Stripe::Customer.construct_from(id: "cus_replace") },
        session_create: ->(*) { CHECKOUT_SESSION.call(id: created_session_ids.shift) },
        session_retrieve: ->(*) { CHECKOUT_SESSION.call(id: "cs_monthly_old") },
        session_expire: ->(session_id, _params, _options) {
          expired_session_ids << session_id
          CHECKOUT_SESSION.call(id: session_id, status: "expired")
        }
      ) do
        create_checkout(option_key: "self_managed_monthly")
        replacement = create_checkout(option_key: "self_managed_annual")

        assert_equal "cs_annual_new", replacement.id
      end

      assert_equal [ "cs_monthly_old" ], expired_session_ids
      assert_equal "replaced", @account.billing_checkout_attempts.find_by!(stripe_checkout_session_id: "cs_monthly_old").status
      active_attempt = @account.billing_checkout_attempts.active.find_by!(stripe_checkout_session_id: "cs_annual_new")
      assert_equal "self_managed_annual", active_attempt.option_key
      assert_equal 1, @account.billing_checkout_attempts.active.count
    end

    test "an expired active attempt is retired and replaced" do
      expired_attempt = create_attempt(
        customer_id: "cus_expired",
        session_id: "cs_expired",
        status: "open"
      )

      with_stripe_methods(
        customer_create: ->(*) { flunk("the prior Customer should be reused") },
        session_create: ->(*) { CHECKOUT_SESSION.call(id: "cs_after_expiration") },
        session_retrieve: ->(*) { CHECKOUT_SESSION.call(id: "cs_expired", status: "expired") }
      ) do
        assert_equal "cs_after_expiration", create_checkout(option_key: "self_managed_monthly").id
      end

      assert_equal "expired", expired_attempt.reload.status
      assert_equal "cs_after_expiration", @account.billing_checkout_attempts.active.first.stripe_checkout_session_id
    end

    test "a canceled attempt does not block a future Checkout and reuses its Customer" do
      canceled_attempt = create_attempt(
        customer_id: "cus_canceled",
        session_id: "cs_canceled",
        status: "canceled"
      )

      with_stripe_methods(
        customer_create: ->(*) { flunk("the prior Customer should be reused") },
        session_create: ->(*) { CHECKOUT_SESSION.call(id: "cs_after_cancel") }
      ) do
        assert_equal "cs_after_cancel", create_checkout(option_key: "self_managed_monthly").id
      end

      assert_equal "canceled", canceled_attempt.reload.status
      assert_equal "cs_after_cancel", @account.billing_checkout_attempts.active.first.stripe_checkout_session_id
    end

    test "a completed Stripe Session blocks another Checkout until its webhook synchronizes" do
      attempt = create_attempt(
        customer_id: "cus_submitted",
        session_id: "cs_submitted",
        status: "open"
      )

      with_stripe_methods(
        customer_create: ->(*) { flunk("the prior Customer should be reused") },
        session_create: ->(*) { flunk("a second Session must not be created") },
        session_retrieve: ->(*) { CHECKOUT_SESSION.call(id: "cs_submitted", status: "complete") }
      ) do
        assert_raises(StripeCheckoutSessionCreator::InvalidAccountError) do
          create_checkout(option_key: "self_managed_monthly")
        end
      end

      assert_equal "submitted", attempt.reload.status
      assert_equal 1, @account.billing_checkout_attempts.active.count
    end

    test "unknown and disabled billing options are rejected before Stripe is called" do
      assert_no_stripe_calls do
        assert_raises(StripeCheckoutSessionCreator::InvalidOptionError) do
          create_checkout(option_key: "price_attacker_supplied")
        end
      end

      definitions = SubscriptionPlanCatalog::DEFAULT_DEFINITIONS.map(&:deep_dup)
      definitions.first[:enabled] = false
      catalog = SubscriptionPlanCatalog.new(
        price_ids: {
          "self_managed_monthly" => MONTHLY_PRICE_ID,
          "self_managed_annual" => ANNUAL_PRICE_ID
        },
        definitions: definitions
      )

      assert_no_stripe_calls do
        assert_raises(StripeCheckoutSessionCreator::InvalidOptionError) do
          StripeCheckoutSessionCreator.new(
            account: @account,
            option_key: "self_managed_monthly",
            success_url: success_url,
            cancel_url: cancel_url,
            catalog: catalog
          ).call
        end
      end
    end

    test "Stripe API failure preserves the attempt idempotency key and leaves the Subscription unchanged" do
      original_subscription = subscription_state(@account.subscription)
      log_output = capture_rails_logs do
        with_stripe_methods(
          customer_create: ->(*) { Stripe::Customer.construct_from(id: "cus_not_persisted") },
          session_create: ->(*) { raise Stripe::APIConnectionError, "private Stripe transport details" }
        ) do
          assert_raises(StripeCheckoutSessionCreator::CheckoutError) do
            create_checkout(option_key: "self_managed_monthly")
          end
        end
      end

      attempt = @account.billing_checkout_attempts.find_by!(status: "creating")
      assert attempt.idempotency_key.present?
      assert_equal original_subscription, subscription_state(@account.subscription.reload)
      assert_includes log_output, "Stripe Checkout creation failed"
      assert_includes log_output, "Stripe::APIConnectionError"
      assert_not_includes log_output, "private Stripe transport details"
      assert_not_includes log_output, SECRET_KEY
      assert_not_includes log_output, MONTHLY_PRICE_ID
    end

    test "an invalid Checkout redirect URL expires the Session and closes its attempt" do
      expired_session_ids = []
      original_subscription = subscription_state(@account.subscription)

      with_stripe_methods(
        customer_create: ->(*) { Stripe::Customer.construct_from(id: "cus_invalid_redirect") },
        session_create: ->(*) {
          Stripe::Checkout::Session.construct_from(
            id: "cs_invalid_redirect",
            status: "open",
            url: "https://attacker.example.test/checkout"
          )
        },
        session_expire: ->(session_id, _params, _options) {
          expired_session_ids << session_id
          CHECKOUT_SESSION.call(id: session_id, status: "expired")
        }
      ) do
        assert_raises(StripeCheckoutSessionCreator::CheckoutError) do
          create_checkout(option_key: "self_managed_monthly")
        end
      end

      assert_equal [ "cs_invalid_redirect" ], expired_session_ids
      assert_equal "canceled", @account.billing_checkout_attempts.find_by!(
        stripe_customer_id: "cus_invalid_redirect"
      ).status
      assert_equal original_subscription, subscription_state(@account.subscription.reload)
    end

    test "retry after an ambiguous Stripe failure uses the same Session idempotency key" do
      create_calls = 0
      idempotency_keys = []

      with_stripe_methods(
        customer_create: ->(*) { Stripe::Customer.construct_from(id: "cus_ambiguous_retry") },
        session_create: ->(_params, options) {
          create_calls += 1
          idempotency_keys << options.fetch(:idempotency_key)
          raise Stripe::APIConnectionError, "ambiguous response" if create_calls == 1

          CHECKOUT_SESSION.call(id: "cs_ambiguous_retry")
        }
      ) do
        assert_raises(StripeCheckoutSessionCreator::CheckoutError) do
          create_checkout(option_key: "self_managed_monthly")
        end

        assert_raises(StripeCheckoutSessionCreator::InvalidOptionError) do
          create_checkout(option_key: "self_managed_annual")
        end

        assert_equal "cs_ambiguous_retry", create_checkout(option_key: "self_managed_monthly").id
      end

      assert_equal 2, create_calls
      assert_equal 1, idempotency_keys.uniq.length
      assert_equal 1, @account.billing_checkout_attempts.count
      assert_equal "open", @account.billing_checkout_attempts.first.status
      assert_equal "self_managed_monthly", @account.billing_checkout_attempts.first.option_key
    end

    test "a Customer associated with another account is rejected" do
      other_account = create_account(name: "Other Stripe Customer Owner")
      create_attempt(account: other_account, customer_id: "cus_conflict", status: "canceled")
      create_attempt(customer_id: "cus_conflict", status: "canceled")

      assert_no_stripe_calls do
        assert_raises(StripeCheckoutSessionCreator::InvalidAccountError) do
          create_checkout(option_key: "self_managed_monthly")
        end
      end
    end

    test "an account with an existing Stripe subscription cannot create another Checkout" do
      @account.subscription.update!(
        provider: "stripe",
        external_customer_id: "cus_subscribed",
        external_subscription_id: "sub_existing",
        plan: "self_managed",
        status: "trialing"
      )

      assert_no_stripe_calls do
        assert_raises(StripeCheckoutSessionCreator::InvalidAccountError) do
          create_checkout(option_key: "self_managed_monthly")
        end
      end
    end

    test "a reserved open attempt is not reused after its webhook completes" do
      attempt = create_attempt(
        customer_id: "cus_completed_between_steps",
        session_id: "cs_completed_between_steps",
        status: "open"
      )
      creator = checkout_creator(option_key: "self_managed_monthly")
      option = creator.send(:selected_option)
      customer_id = creator.send(:checkout_customer_id)
      attempt_id = creator.send(:reserve_attempt, option, customer_id)

      StripeCheckoutCompletionSynchronizer.call(completed_checkout_session(attempt))

      assert_no_stripe_calls do
        assert_raises(StripeCheckoutSessionCreator::InvalidAccountError) do
          creator.send(:advance_attempt, attempt_id, option, customer_id)
        end
      end

      assert_equal "completed", attempt.reload.status
      assert_equal 0, @account.billing_checkout_attempts.active.count
      assert_equal "sub_completed_between_steps", @account.subscription.reload.external_subscription_id
    end

    test "a creating attempt cannot activate after the Subscription becomes Stripe-backed" do
      attempt = create_attempt(
        customer_id: "cus_creating_stale",
        session_id: nil,
        status: "creating"
      )
      @account.subscription.update!(
        provider: "stripe",
        external_customer_id: "cus_creating_stale",
        external_subscription_id: "sub_creating_stale",
        plan: "self_managed",
        status: "trialing"
      )

      assert_no_stripe_calls do
        assert_raises(StripeCheckoutSessionCreator::InvalidAccountError) do
          create_checkout(option_key: "self_managed_monthly")
        end
      end

      assert_equal "completed", attempt.reload.status
      assert_equal 0, @account.billing_checkout_attempts.active.count
    end

    test "a Session response is expired when the Subscription becomes authoritative during creation" do
      account = @account
      expired_session_ids = []

      with_stripe_methods(
        customer_create: ->(*) { Stripe::Customer.construct_from(id: "cus_activation_race") },
        session_create: ->(*) {
          account.subscription.update!(
            provider: "stripe",
            external_customer_id: "cus_activation_race",
            external_subscription_id: "sub_activation_race",
            plan: "self_managed",
            status: "trialing"
          )
          CHECKOUT_SESSION.call(id: "cs_activation_race")
        },
        session_expire: ->(session_id, _params, _options) {
          expired_session_ids << session_id
          CHECKOUT_SESSION.call(id: session_id, status: "expired")
        }
      ) do
        assert_raises(StripeCheckoutSessionCreator::InvalidAccountError) do
          create_checkout(option_key: "self_managed_monthly")
        end
      end

      attempt = @account.billing_checkout_attempts.find_by!(stripe_customer_id: "cus_activation_race")
      assert_equal [ "cs_activation_race" ], expired_session_ids
      assert_equal "canceled", attempt.status
      assert_equal 0, @account.billing_checkout_attempts.active.count
      assert_equal "sub_activation_race", @account.subscription.reload.external_subscription_id
    end

    private

    def create_checkout(option_key:)
      checkout_creator(option_key: option_key).call
    end

    def checkout_creator(option_key:, catalog: nil)
      StripeCheckoutSessionCreator.new(
        account: @account,
        option_key: option_key,
        success_url: success_url,
        cancel_url: cancel_url,
        catalog: catalog
      )
    end

    def completed_checkout_session(attempt)
      account_reference = StripeAccountReference.generate(@account)

      Stripe::Checkout::Session.construct_from(
        id: attempt.stripe_checkout_session_id,
        mode: "subscription",
        customer: attempt.stripe_customer_id,
        subscription: "sub_completed_between_steps",
        client_reference_id: account_reference,
        metadata: {
          StripeCheckoutSessionCreator::ACCOUNT_REFERENCE_KEY => account_reference,
          StripeCheckoutSessionCreator::ATTEMPT_REFERENCE_KEY =>
            StripeCheckoutAttemptReference.generate(attempt),
          StripeCheckoutSessionCreator::OPTION_KEY => attempt.option_key
        }
      )
    end

    def create_attempt(account: @account, customer_id:, session_id: SecureRandom.uuid,
      option_key: "self_managed_monthly", status:)
      BillingCheckoutAttempt.create!(
        account: account,
        option_key: option_key,
        stripe_customer_id: customer_id,
        stripe_checkout_session_id: session_id,
        idempotency_key: SecureRandom.uuid,
        status: status
      )
    end

    def success_url
      "https://app.example.test/billing/checkout/success"
    end

    def cancel_url
      "https://app.example.test/billing/checkout/cancel"
    end

    def subscription_state(subscription)
      subscription.attributes.slice(
        "plan",
        "status",
        "provider",
        "external_customer_id",
        "external_subscription_id",
        "trial_ends_at",
        "current_period_ends_at",
        "cancel_at_period_end",
        "cancel_at",
        "canceled_at",
        "entitlement_ended_at",
        "past_due_observed_at",
        "last_synced_at"
      )
    end

    def assert_no_stripe_calls(&block)
      with_stripe_methods(
        customer_create: ->(*) { flunk("Stripe Customer API should not be called") },
        session_create: ->(*) { flunk("Stripe Checkout API should not be called") },
        session_retrieve: ->(*) { flunk("Stripe Checkout retrieve should not be called") },
        session_expire: ->(*) { flunk("Stripe Checkout expire should not be called") },
        &block
      )
    end

    def with_stripe_methods(customer_create:, session_create:, session_retrieve: nil, session_expire: nil)
      session_retrieve ||= ->(*) { flunk("Stripe Checkout retrieve was unexpected") }
      session_expire ||= ->(*) { flunk("Stripe Checkout expire was unexpected") }

      with_singleton_method(Stripe::Customer, :create, customer_create) do
        with_singleton_method(Stripe::Checkout::Session, :create, session_create) do
          with_singleton_method(Stripe::Checkout::Session, :retrieve, session_retrieve) do
            with_singleton_method(Stripe::Checkout::Session, :expire, session_expire) do
              yield
            end
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
