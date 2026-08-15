module Billing
  class StripeConfiguration
    class MissingConfigurationError < StandardError; end

    class << self
      def secret_key
        Rails.configuration.x.stripe.secret_key.presence
      end

      def publishable_key
        Rails.configuration.x.stripe.publishable_key.presence
      end

      def webhook_secret
        Rails.configuration.x.stripe.webhook_secret.presence
      end

      def expected_livemode
        case Rails.configuration.x.stripe.livemode
        when true, "true" then true
        when false, "false" then false
        end
      end

      def self_managed_monthly_price_id
        Rails.configuration.x.stripe.self_managed_monthly_price_id.presence
      end

      def self_managed_annual_price_id
        Rails.configuration.x.stripe.self_managed_annual_price_id.presence
      end

      def webhook_secret!
        webhook_secret || raise(MissingConfigurationError, "Stripe webhook signing secret is not configured")
      end

      def secret_key!
        secret_key || raise(MissingConfigurationError, "Stripe API secret is not configured")
      end

      def expected_livemode!
        value = expected_livemode
        return value unless value.nil?

        raise MissingConfigurationError, "Stripe webhook mode is not configured"
      end
    end
  end
end
