module Billing
  class SubscriptionPlanCatalog
    class ConfigurationError < StandardError; end

    SELF_MANAGED_PLAN_KEY = "self_managed"
    SELF_MANAGED_MONTHLY_KEY = "self_managed_monthly"
    SELF_MANAGED_ANNUAL_KEY = "self_managed_annual"

    SUPPORTED_PLAN_KEYS = [ SELF_MANAGED_PLAN_KEY ].freeze
    SUPPORTED_INTERVALS = %w[month year].freeze
    SUPPORTED_CURRENCIES = %w[usd].freeze

    PRICE_ID_ENV_KEYS = {
      SELF_MANAGED_MONTHLY_KEY => "STRIPE_SELF_MANAGED_MONTHLY_PRICE_ID",
      SELF_MANAGED_ANNUAL_KEY => "STRIPE_SELF_MANAGED_ANNUAL_PRICE_ID"
    }.freeze

    Option = Struct.new(
      :key,
      :plan_key,
      :name,
      :description,
      :interval,
      :interval_count,
      :amount_cents,
      :currency,
      :stripe_price_id,
      :trial_days,
      :enabled,
      :entitlements,
      keyword_init: true
    ) do
      def enabled?
        enabled == true
      end

      def display_price
        price = amount_cents.to_i
        whole_dollars = price / 100
        cents = price % 100
        formatted_amount = cents.zero? ? whole_dollars.to_s : format("%.2f", price / 100.0)

        "$#{formatted_amount}/#{interval}"
      end
    end

    DEFAULT_ENTITLEMENTS = {
      unlimited_vessels: true,
      owner_user_limit: 1,
      crew_management: false
    }.freeze

    DEFAULT_DEFINITIONS = [
      {
        key: SELF_MANAGED_MONTHLY_KEY,
        plan_key: SELF_MANAGED_PLAN_KEY,
        name: "Self Managed",
        description: "For owners managing their own vessel binder.",
        interval: "month",
        interval_count: 1,
        amount_cents: 1_400,
        currency: "usd",
        trial_days: 7,
        enabled: true,
        entitlements: DEFAULT_ENTITLEMENTS
      },
      {
        key: SELF_MANAGED_ANNUAL_KEY,
        plan_key: SELF_MANAGED_PLAN_KEY,
        name: "Self Managed",
        description: "For owners managing their own vessel binder, with one month free.",
        interval: "year",
        interval_count: 1,
        amount_cents: 15_400,
        currency: "usd",
        trial_days: 7,
        enabled: true,
        entitlements: DEFAULT_ENTITLEMENTS
      }
    ].map(&:freeze).freeze

    class << self
      def enabled_options
        new.enabled_options
      end

      def find(option_key)
        new.find(option_key)
      end

      def fetch(option_key)
        new.fetch(option_key)
      end

      def find_by_stripe_price_id(stripe_price_id)
        new.find_by_stripe_price_id(stripe_price_id)
      end

      def options_for_plan(plan_key)
        new.options_for_plan(plan_key)
      end

      def price_ids_from_configuration
        {
          SELF_MANAGED_MONTHLY_KEY => StripeConfiguration.self_managed_monthly_price_id,
          SELF_MANAGED_ANNUAL_KEY => StripeConfiguration.self_managed_annual_price_id
        }
      end
    end

    attr_reader :options

    def initialize(price_ids: self.class.price_ids_from_configuration, definitions: DEFAULT_DEFINITIONS)
      @price_ids = price_ids.transform_keys(&:to_s)
      built_options = definitions.map { |definition| build_option(definition) }
      built_options.each(&:freeze)
      @options = built_options.freeze

      validate!
    end

    def enabled_options
      options.select(&:enabled?).freeze
    end

    def find(option_key)
      options_by_key[option_key.to_s]
    end

    def fetch(option_key)
      find(option_key) || raise(KeyError, "Unknown subscription billing option: #{option_key}")
    end

    def find_by_stripe_price_id(stripe_price_id)
      return if stripe_price_id.blank?

      options.find { |option| option.stripe_price_id == stripe_price_id.to_s }
    end

    def options_for_plan(plan_key)
      enabled_options.select { |option| option.plan_key == plan_key.to_s }.freeze
    end

    private

    def build_option(definition)
      normalized_definition = definition.with_indifferent_access
      key = normalized_definition.fetch(:key).to_s

      Option.new(
        key: key,
        plan_key: normalized_definition.fetch(:plan_key).to_s,
        name: normalized_definition.fetch(:name).to_s,
        description: normalized_definition.fetch(:description).to_s,
        interval: normalized_definition.fetch(:interval).to_s,
        interval_count: normalized_definition.fetch(:interval_count),
        amount_cents: normalized_definition.fetch(:amount_cents),
        currency: normalized_definition.fetch(:currency).to_s,
        stripe_price_id: @price_ids[key].presence,
        trial_days: normalized_definition.fetch(:trial_days),
        enabled: normalized_definition.fetch(:enabled),
        entitlements: normalized_definition.fetch(:entitlements, {}).dup.freeze
      )
    rescue KeyError => error
      raise ConfigurationError, "Subscription billing option is missing required configuration: #{error.key}"
    end

    def validate!
      errors = []
      errors.concat(duplicate_option_errors)
      errors.concat(duplicate_price_id_errors)
      options.each { |option| errors.concat(option_errors(option)) }

      raise ConfigurationError, errors.join("; ") if errors.any?

      true
    end

    def duplicate_option_errors
      duplicate_keys = duplicates(options.map(&:key))
      return [] if duplicate_keys.empty?

      [ "Duplicate subscription billing option keys: #{duplicate_keys.join(', ')}" ]
    end

    def duplicate_price_id_errors
      options
        .select { |option| option.stripe_price_id.present? }
        .group_by(&:stripe_price_id)
        .values
        .select { |matching_options| matching_options.many? }
        .map do |matching_options|
          option_keys = matching_options.map(&:key).join(", ")
          "Duplicate Stripe Price ID configured for options: #{option_keys}"
        end
    end

    def option_errors(option)
      errors = []
      errors << "#{option.key} name is required" if option.name.blank?
      errors << "#{option.key} description is required" if option.description.blank?
      if option.plan_key.blank?
        errors << "#{option.key} plan key is required"
      elsif SUPPORTED_PLAN_KEYS.exclude?(option.plan_key)
        errors << "#{option.key} plan key is not supported"
      end
      errors << "#{option.key} Stripe Price ID is required (set #{price_id_env_key(option.key)})" if option.stripe_price_id.blank?
      errors << "#{option.key} interval is not supported" unless SUPPORTED_INTERVALS.include?(option.interval)
      errors << "#{option.key} currency is not supported" unless SUPPORTED_CURRENCIES.include?(option.currency)
      errors << "#{option.key} amount must be a positive integer" unless positive_integer?(option.amount_cents)
      errors << "#{option.key} interval count must be a positive integer" unless positive_integer?(option.interval_count)
      errors << "#{option.key} trial days must be a non-negative integer" unless non_negative_integer?(option.trial_days)
      errors << "#{option.key} enabled must be true or false" unless [ true, false ].include?(option.enabled)
      errors
    end

    def duplicates(values)
      values.tally.select { |_value, count| count > 1 }.keys
    end

    def positive_integer?(value)
      value.is_a?(Integer) && value.positive?
    end

    def non_negative_integer?(value)
      value.is_a?(Integer) && value >= 0
    end

    def price_id_env_key(option_key)
      PRICE_ID_ENV_KEYS.fetch(option_key, "STRIPE_PRICE_ID")
    end

    def options_by_key
      @options_by_key ||= options.index_by(&:key).freeze
    end
  end
end
