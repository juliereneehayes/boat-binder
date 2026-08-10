require "test_helper"

module Billing
  class SubscriptionPlanCatalogTest < ActiveSupport::TestCase
    MONTHLY_PRICE_ID = "price_self_managed_monthly_test"
    ANNUAL_PRICE_ID = "price_self_managed_annual_test"

    test "monthly option exposes expected product and billing attributes" do
      option = catalog.fetch("self_managed_monthly")

      assert_equal "self_managed_monthly", option.key
      assert_equal "self_managed", option.plan_key
      assert_equal "Self Managed", option.name
      assert_equal "month", option.interval
      assert_equal 1, option.interval_count
      assert_equal 1_400, option.amount_cents
      assert_equal "$14/month", option.display_price
      assert_equal "usd", option.currency
      assert_equal 7, option.trial_days
      assert_equal MONTHLY_PRICE_ID, option.stripe_price_id
      assert option.enabled?
      assert option.entitlements.fetch(:unlimited_vessels)
      assert_equal 1, option.entitlements.fetch(:owner_user_limit)
      assert_not option.entitlements.fetch(:crew_management)
    end

    test "annual option exposes expected product and billing attributes" do
      option = catalog.fetch("self_managed_annual")

      assert_equal "self_managed_annual", option.key
      assert_equal "self_managed", option.plan_key
      assert_equal "Self Managed", option.name
      assert_includes option.description, "one month free"
      assert_equal "year", option.interval
      assert_equal 15_400, option.amount_cents
      assert_equal "$154/year", option.display_price
      assert_equal "usd", option.currency
      assert_equal 7, option.trial_days
      assert_equal ANNUAL_PRICE_ID, option.stripe_price_id
      assert option.enabled?
    end

    test "monthly and annual options share the stable self managed plan key" do
      options = catalog.options_for_plan("self_managed")

      assert_equal %w[self_managed_monthly self_managed_annual], options.map(&:key)
      assert_equal [ "self_managed" ], options.map(&:plan_key).uniq
    end

    test "enabled options lists available billing options" do
      assert_equal %w[self_managed_monthly self_managed_annual], catalog.enabled_options.map(&:key)
    end

    test "catalog options and entitlement metadata are immutable" do
      option = catalog.fetch("self_managed_monthly")

      assert_predicate catalog.options, :frozen?
      assert_predicate option, :frozen?
      assert_predicate option.entitlements, :frozen?
      assert_raises(FrozenError) { option.name = "Changed" }
    end

    test "looks up options by stable option key" do
      assert_equal "month", catalog.find("self_managed_monthly").interval
      assert_equal "year", catalog.fetch("self_managed_annual").interval
      assert_nil catalog.find("unknown_option")
      assert_raises(KeyError) { catalog.fetch("unknown_option") }
    end

    test "looks up options by Stripe price id" do
      assert_equal "self_managed_monthly", catalog.find_by_stripe_price_id(MONTHLY_PRICE_ID).key
      assert_equal "self_managed_annual", catalog.find_by_stripe_price_id(ANNUAL_PRICE_ID).key
      assert_nil catalog.find_by_stripe_price_id("price_unknown")
      assert_nil catalog.find_by_stripe_price_id(nil)
    end

    test "class level lookups read configured Stripe price ids without real credentials" do
      with_plan_price_configuration(monthly: MONTHLY_PRICE_ID, annual: ANNUAL_PRICE_ID) do
        assert_equal MONTHLY_PRICE_ID,
          SubscriptionPlanCatalog.find("self_managed_monthly").stripe_price_id
        assert_equal ANNUAL_PRICE_ID,
          SubscriptionPlanCatalog.find_by_stripe_price_id(ANNUAL_PRICE_ID).stripe_price_id
      end
    end

    test "missing Stripe price ids fail clearly without exposing secrets" do
      error = assert_raises(SubscriptionPlanCatalog::ConfigurationError) do
        build_catalog(price_ids: { "self_managed_monthly" => nil, "self_managed_annual" => ANNUAL_PRICE_ID })
      end

      assert_includes error.message, "self_managed_monthly Stripe Price ID is required"
      assert_includes error.message, "STRIPE_SELF_MANAGED_MONTHLY_PRICE_ID"
      assert_not_includes error.message, ANNUAL_PRICE_ID
    end

    test "duplicate option keys are rejected" do
      duplicate_definition = definition_for("self_managed_annual").merge(key: "self_managed_monthly")

      error = assert_raises(SubscriptionPlanCatalog::ConfigurationError) do
        build_catalog(definitions: [ definition_for("self_managed_monthly"), duplicate_definition ])
      end

      assert_includes error.message, "Duplicate subscription billing option keys"
    end

    test "duplicate Stripe price ids are rejected" do
      error = assert_raises(SubscriptionPlanCatalog::ConfigurationError) do
        build_catalog(
          price_ids: {
            "self_managed_monthly" => MONTHLY_PRICE_ID,
            "self_managed_annual" => MONTHLY_PRICE_ID
          }
        )
      end

      assert_includes error.message,
        "Duplicate Stripe Price ID configured for options: self_managed_monthly, self_managed_annual"
      assert_not_includes error.message, MONTHLY_PRICE_ID
    end

    test "unknown plan keys are rejected" do
      bad_definition = definition_for("self_managed_monthly").merge(plan_key: "self-managed")

      error = assert_raises(SubscriptionPlanCatalog::ConfigurationError) do
        build_catalog(definitions: [ bad_definition, definition_for("self_managed_annual") ])
      end

      assert_includes error.message, "self_managed_monthly plan key is not supported"
    end

    test "unsupported intervals are rejected" do
      bad_definition = definition_for("self_managed_monthly").merge(interval: "week")

      error = assert_raises(SubscriptionPlanCatalog::ConfigurationError) do
        build_catalog(definitions: [ bad_definition, definition_for("self_managed_annual") ])
      end

      assert_includes error.message, "self_managed_monthly interval is not supported"
    end

    test "unsupported currencies are rejected" do
      bad_definition = definition_for("self_managed_monthly").merge(currency: "cad")

      error = assert_raises(SubscriptionPlanCatalog::ConfigurationError) do
        build_catalog(definitions: [ bad_definition, definition_for("self_managed_annual") ])
      end

      assert_includes error.message, "self_managed_monthly currency is not supported"
    end

    test "invalid amounts are rejected" do
      bad_definition = definition_for("self_managed_monthly").merge(amount_cents: 0)

      error = assert_raises(SubscriptionPlanCatalog::ConfigurationError) do
        build_catalog(definitions: [ bad_definition, definition_for("self_managed_annual") ])
      end

      assert_includes error.message, "self_managed_monthly amount must be a positive integer"
    end

    test "invalid trial durations are rejected" do
      bad_definition = definition_for("self_managed_monthly").merge(trial_days: -1)

      error = assert_raises(SubscriptionPlanCatalog::ConfigurationError) do
        build_catalog(definitions: [ bad_definition, definition_for("self_managed_annual") ])
      end

      assert_includes error.message, "self_managed_monthly trial days must be a non-negative integer"
    end

    test "invalid enabled values are rejected" do
      bad_definition = definition_for("self_managed_monthly").merge(enabled: "true")

      error = assert_raises(SubscriptionPlanCatalog::ConfigurationError) do
        build_catalog(definitions: [ bad_definition, definition_for("self_managed_annual") ])
      end

      assert_includes error.message, "self_managed_monthly enabled must be true or false"
    end

    test "missing required attributes fail with a catalog configuration error" do
      bad_definition = definition_for("self_managed_monthly").except(:name)

      error = assert_raises(SubscriptionPlanCatalog::ConfigurationError) do
        build_catalog(definitions: [ bad_definition, definition_for("self_managed_annual") ])
      end

      assert_includes error.message, "missing required configuration: name"
    end

    test "catalog loading and lookups do not call Stripe APIs" do
      assert_no_stripe_price_lookup do
        loaded_catalog = catalog

        assert_equal 2, loaded_catalog.enabled_options.size
        assert_equal "self_managed_monthly", loaded_catalog.find_by_stripe_price_id(MONTHLY_PRICE_ID).key
      end
    end

    private

    def catalog
      build_catalog
    end

    def build_catalog(price_ids: default_price_ids, definitions: SubscriptionPlanCatalog::DEFAULT_DEFINITIONS)
      SubscriptionPlanCatalog.new(price_ids: price_ids, definitions: definitions)
    end

    def default_price_ids
      {
        "self_managed_monthly" => MONTHLY_PRICE_ID,
        "self_managed_annual" => ANNUAL_PRICE_ID
      }
    end

    def definition_for(key)
      SubscriptionPlanCatalog::DEFAULT_DEFINITIONS.find { |definition| definition.fetch(:key) == key }.dup
    end

    def with_plan_price_configuration(monthly:, annual:)
      previous_monthly = Rails.configuration.x.stripe.self_managed_monthly_price_id
      previous_annual = Rails.configuration.x.stripe.self_managed_annual_price_id
      Rails.configuration.x.stripe.self_managed_monthly_price_id = monthly
      Rails.configuration.x.stripe.self_managed_annual_price_id = annual

      yield
    ensure
      Rails.configuration.x.stripe.self_managed_monthly_price_id = previous_monthly
      Rails.configuration.x.stripe.self_managed_annual_price_id = previous_annual
    end

    def assert_no_stripe_price_lookup
      original_retrieve = Stripe::Price.method(:retrieve) if Stripe::Price.respond_to?(:retrieve)
      Stripe::Price.define_singleton_method(:retrieve) { |*| raise "Stripe API should not be called" }

      yield
    ensure
      if original_retrieve
        Stripe::Price.define_singleton_method(:retrieve, original_retrieve)
      elsif Stripe::Price.singleton_class.method_defined?(:retrieve)
        Stripe::Price.singleton_class.remove_method(:retrieve)
      end
    end
  end
end
