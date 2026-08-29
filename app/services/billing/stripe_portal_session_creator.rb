module Billing
  class StripePortalSessionCreator
    PORTAL_HOST = "billing.stripe.com"
    PORTAL_PATH = "/p/session"
    SUPPORTED_LIFECYCLE_PHASES = %i[current_entitlement payment_recovery_pending].freeze

    class PortalError < StandardError; end
    class InvalidAccountError < PortalError; end
    class InvalidSessionError < PortalError; end

    def self.call(account:, return_url:)
      new(account:, return_url:).call
    end

    def self.eligible_account?(account, now: Time.current)
      return false unless account&.persisted? && account.active? && account.account_type == "client"

      phase = SelfManagedEntitlement.new(account:, now:).lifecycle_phase
      SUPPORTED_LIFECYCLE_PHASES.include?(phase)
    end

    def initialize(account:, return_url:)
      @account = account
      @return_url = return_url
    end

    def call
      validate_account!
      configuration_id = StripeConfiguration.billing_portal_configuration_id!
      expected_livemode = StripeConfiguration.expected_livemode!
      customer_id = account.subscription.external_customer_id

      session = Stripe::BillingPortal::Session.create(
        {
          customer: customer_id,
          configuration: configuration_id,
          return_url: return_url
        },
        { api_key: StripeConfiguration.secret_key! }
      )

      validate_session!(session, customer_id:, configuration_id:, expected_livemode:)
      session
    rescue PortalError
      raise
    rescue Stripe::StripeError => error
      Rails.logger.error("Stripe Billing Portal session creation failed error=#{error.class.name}")
      raise PortalError, "Stripe Billing Portal could not be opened"
    end

    private

    attr_reader :account, :return_url

    def validate_account!
      return if self.class.eligible_account?(account)

      raise InvalidAccountError, "Account is not eligible for Stripe Billing Portal"
    end

    def validate_session!(session, customer_id:, configuration_id:, expected_livemode:)
      valid = valid_session_shape?(session) &&
        stripe_id(session.customer) == customer_id &&
        stripe_id(session.configuration) == configuration_id &&
        session.livemode == expected_livemode &&
        session.return_url.to_s == return_url.to_s &&
        valid_portal_url?(session.url)
      return if valid

      raise InvalidSessionError, "Stripe Billing Portal Session did not match the request"
    end

    def valid_session_shape?(session)
      %i[customer configuration livemode return_url url].all? { |attribute| session.respond_to?(attribute) }
    end

    def stripe_id(value)
      value.respond_to?(:id) ? value.id.to_s : value.to_s
    end

    def valid_portal_url?(value)
      uri = URI.parse(value.to_s)
      uri.is_a?(URI::HTTPS) &&
        uri.host == PORTAL_HOST &&
        uri.port == 443 &&
        uri.userinfo.nil? &&
        valid_portal_path?(uri.path)
    rescue URI::InvalidURIError
      false
    end

    def valid_portal_path?(path)
      path == PORTAL_PATH || path.start_with?("#{PORTAL_PATH}/")
    end
  end
end
