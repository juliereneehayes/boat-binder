require "test_helper"

module Billing
  class StripeCheckoutSessionCreatorTest < ActiveSupport::TestCase
    SECRET_KEY = "sk_test_checkout"
    MONTHLY_PRICE_ID = "price_checkout_monthly"
    ANNUAL_PRICE_ID = "price_checkout_annual"

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

    test "monthly Checkout uses catalog price trial and server metadata" do
      customer_request = nil
      checkout_request = nil
      customer = Stripe::Customer.construct_from(id: "cus_checkout_monthly")
      checkout_session = stripe_checkout_session(id: "cs_monthly")

      with_singleton_method(Stripe::Customer, :create, ->(params, options) {
        customer_request = [ params, options ]
        customer
      }) do
        with_singleton_method(Stripe::Checkout::Session, :create, ->(params, options) {
          checkout_request = [ params, options ]
          checkout_session
        }) do
          result = create_checkout(option_key: "self_managed_monthly")

          assert_equal checkout_session, result
        end
      end

      customer_params, customer_options = customer_request
      checkout_params, checkout_options = checkout_request
      account_reference = customer_params.dig(:metadata, StripeCheckoutSessionCreator::ACCOUNT_REFERENCE_KEY)

      assert_equal @account, StripeAccountReference.find!(account_reference)
      assert_equal SECRET_KEY, customer_options.fetch(:api_key)
      assert_match(/\Aboat-binder-customer-v1-/, customer_options.fetch(:idempotency_key))
      assert_equal "subscription", checkout_params.fetch(:mode)
      assert_equal "cus_checkout_monthly", checkout_params.fetch(:customer)
      assert_equal account_reference, checkout_params.fetch(:client_reference_id)
      assert_equal MONTHLY_PRICE_ID, checkout_params.dig(:line_items, 0, :price)
      assert_equal 1, checkout_params.dig(:line_items, 0, :quantity)
      assert_equal 7, checkout_params.dig(:subscription_data, :trial_period_days)
      assert_equal "always", checkout_params.fetch(:payment_method_collection)
      assert_equal "self_managed_monthly",
        checkout_params.dig(:subscription_data, :metadata, StripeCheckoutSessionCreator::OPTION_KEY)
      assert_equal "https://app.example.test/billing/checkout/success", checkout_params.fetch(:success_url)
      assert_equal "https://app.example.test/billing/checkout/cancel", checkout_params.fetch(:cancel_url)
      assert_equal SECRET_KEY, checkout_options.fetch(:api_key)

      subscription = @account.subscription.reload
      assert_equal "stripe", subscription.provider
      assert_equal "cus_checkout_monthly", subscription.external_customer_id
      assert_nil subscription.external_subscription_id
      assert_equal "legacy", subscription.plan
      assert_equal "active", subscription.status
    end

    test "annual Checkout uses the annual catalog price and reuses this account customer" do
      @account.subscription.update!(provider: "stripe", external_customer_id: "cus_existing")
      checkout_request = nil
      checkout_session = stripe_checkout_session(id: "cs_annual")

      with_singleton_method(Stripe::Customer, :create, ->(*) { flunk("existing Stripe Customer should be reused") }) do
        with_singleton_method(Stripe::Checkout::Session, :create, ->(params, _options) {
          checkout_request = params
          checkout_session
        }) do
          create_checkout(option_key: "self_managed_annual")
        end
      end

      assert_equal "cus_existing", checkout_request.fetch(:customer)
      assert_equal ANNUAL_PRICE_ID, checkout_request.dig(:line_items, 0, :price)
      assert_equal 7, checkout_request.dig(:subscription_data, :trial_period_days)
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

    test "Stripe API failure leaves the local subscription unchanged and logs no sensitive details" do
      original_attributes = subscription_state(@account.subscription)
      log_output = capture_rails_logs do
        with_singleton_method(Stripe::Customer, :create, ->(*) {
          Stripe::Customer.construct_from(id: "cus_not_persisted")
        }) do
          with_singleton_method(Stripe::Checkout::Session, :create, ->(*) {
            raise Stripe::APIConnectionError, "private Stripe transport details"
          }) do
            assert_raises(StripeCheckoutSessionCreator::CheckoutError) do
              create_checkout(option_key: "self_managed_monthly")
            end
          end
        end
      end

      assert_equal original_attributes, subscription_state(@account.subscription.reload)
      assert_includes log_output, "Stripe Checkout creation failed"
      assert_includes log_output, "Stripe::APIConnectionError"
      assert_not_includes log_output, "private Stripe transport details"
      assert_not_includes log_output, SECRET_KEY
      assert_not_includes log_output, MONTHLY_PRICE_ID
    end

    test "an invalid Checkout redirect URL is rejected without a local association" do
      original_attributes = subscription_state(@account.subscription)

      with_singleton_method(Stripe::Customer, :create, ->(*) {
        Stripe::Customer.construct_from(id: "cus_invalid_redirect")
      }) do
        with_singleton_method(Stripe::Checkout::Session, :create, ->(*) {
          Stripe::Checkout::Session.construct_from(
            id: "cs_invalid_redirect",
            url: "https://attacker.example.test/checkout"
          )
        }) do
          assert_raises(StripeCheckoutSessionCreator::CheckoutError) do
            create_checkout(option_key: "self_managed_monthly")
          end
        end
      end

      assert_equal original_attributes, subscription_state(@account.subscription.reload)
    end

    test "customer association persistence failure is sanitized and does not activate locally" do
      subscription = @account.subscription
      original_attributes = subscription_state(subscription)
      checkout_session = stripe_checkout_session(id: "cs_persistence_failure")
      log_output = capture_rails_logs do
        with_singleton_method(Stripe::Customer, :create, ->(*) {
          Stripe::Customer.construct_from(id: "cus_persistence_failure")
        }) do
          with_singleton_method(Stripe::Checkout::Session, :create, ->(*) { checkout_session }) do
            with_singleton_method(subscription, :update!, ->(**) {
              subscription.errors.add(:base, "private database detail")
              raise ActiveRecord::RecordInvalid, subscription
            }) do
              assert_raises(StripeCheckoutSessionCreator::CheckoutError) do
                create_checkout(option_key: "self_managed_monthly")
              end
            end
          end
        end
      end

      assert_equal original_attributes, subscription_state(subscription.reload)
      assert_includes log_output, "Stripe Checkout association failed"
      assert_includes log_output, "ActiveRecord::RecordInvalid"
      assert_not_includes log_output, "private database detail"
    end

    test "customer association shared by another account is rejected" do
      other_account = create_account(name: "Other Stripe Customer Owner")
      other_account.subscription.update!(provider: "stripe", external_customer_id: "cus_conflict")
      @account.subscription.update!(provider: "stripe", external_customer_id: "cus_conflict")

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

    private

    def create_checkout(option_key:)
      StripeCheckoutSessionCreator.call(
        account: @account,
        option_key: option_key,
        success_url: success_url,
        cancel_url: cancel_url
      )
    end

    def stripe_checkout_session(id:)
      Stripe::Checkout::Session.construct_from(
        id: id,
        url: "https://checkout.stripe.com/c/pay/#{id}"
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
        "last_synced_at"
      )
    end

    def assert_no_stripe_calls(&block)
      with_singleton_method(Stripe::Customer, :create, ->(*) { flunk("Stripe Customer API should not be called") }) do
        with_singleton_method(
          Stripe::Checkout::Session,
          :create,
          ->(*) { flunk("Stripe Checkout API should not be called") },
          &block
        )
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
