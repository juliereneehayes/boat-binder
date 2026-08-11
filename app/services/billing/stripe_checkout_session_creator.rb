module Billing
  class StripeCheckoutSessionCreator
    ACCOUNT_REFERENCE_KEY = "boat_binder_account"
    OPTION_KEY = "boat_binder_option"
    CHECKOUT_HOST = "checkout.stripe.com"

    class CheckoutError < StandardError; end
    class InvalidAccountError < CheckoutError; end
    class InvalidOptionError < CheckoutError; end

    def self.call(account:, option_key:, success_url:, cancel_url:)
      new(
        account: account,
        option_key: option_key,
        success_url: success_url,
        cancel_url: cancel_url
      ).call
    end

    def initialize(account:, option_key:, success_url:, cancel_url:, catalog: nil)
      @account = account
      @option_key = option_key.to_s
      @success_url = success_url
      @cancel_url = cancel_url
      @catalog = catalog
    end

    def call
      option = selected_option
      subscription = account.subscription
      validate_subscription!(subscription)

      customer_id = existing_customer_id(subscription) || create_customer
      checkout_session = create_checkout_session(option, customer_id)
      associate_customer!(subscription, customer_id)

      checkout_session
    rescue Stripe::StripeError => error
      Rails.logger.error(
        "Stripe Checkout creation failed option_key=#{option_key.inspect} error=#{error.class.name}"
      )
      raise CheckoutError, "Stripe Checkout could not be started"
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => error
      Rails.logger.error(
        "Stripe Checkout association failed option_key=#{option_key.inspect} error=#{error.class.name}"
      )
      raise CheckoutError, "Stripe Checkout could not be started"
    end

    private

    attr_reader :account, :option_key, :success_url, :cancel_url

    def catalog
      @catalog ||= SubscriptionPlanCatalog.new
    end

    def selected_option
      option = catalog.find(option_key)
      return option if option&.enabled?

      raise InvalidOptionError, "Subscription billing option is unavailable"
    end

    def validate_subscription!(subscription)
      raise InvalidAccountError, "Account subscription state is unavailable" unless subscription
      raise InvalidAccountError, "Account already has a Stripe subscription" if subscription.external_subscription_id.present?
      return if subscription.external_customer_id.blank? || subscription.provider == Subscription::STRIPE_PROVIDER

      raise InvalidAccountError, "Account Stripe Customer association is invalid"
    end

    def existing_customer_id(subscription)
      customer_id = subscription.external_customer_id.presence
      return unless customer_id

      ensure_customer_available!(customer_id)
      customer_id
    end

    def create_customer
      customer = Stripe::Customer.create(
        { metadata: stripe_metadata },
        {
          api_key: StripeConfiguration.secret_key!,
          idempotency_key: customer_idempotency_key
        }
      )
      customer_id = customer.id.to_s.presence
      return customer_id if customer_id

      raise CheckoutError, "Stripe Customer could not be created"
    end

    def create_checkout_session(option, customer_id)
      checkout_session = Stripe::Checkout::Session.create(
        {
          mode: "subscription",
          customer: customer_id,
          client_reference_id: account_reference,
          line_items: [ { price: option.stripe_price_id, quantity: 1 } ],
          payment_method_collection: "always",
          subscription_data: {
            trial_period_days: option.trial_days,
            metadata: stripe_metadata
          },
          metadata: stripe_metadata,
          success_url: success_url,
          cancel_url: cancel_url
        },
        { api_key: StripeConfiguration.secret_key! }
      )
      return checkout_session if checkout_session.id.present? && valid_checkout_url?(checkout_session.url)

      raise CheckoutError, "Stripe Checkout Session was incomplete"
    end

    def valid_checkout_url?(url)
      uri = URI.parse(url.to_s)
      uri.is_a?(URI::HTTPS) && uri.host == CHECKOUT_HOST
    rescue URI::InvalidURIError
      false
    end

    def associate_customer!(subscription, customer_id)
      subscription.with_lock do
        subscription.reload
        validate_subscription!(subscription)
        if subscription.external_customer_id.present? && subscription.external_customer_id != customer_id
          raise InvalidAccountError, "Account Stripe Customer association changed"
        end

        ensure_customer_available!(customer_id)
        subscription.update!(
          provider: Subscription::STRIPE_PROVIDER,
          external_customer_id: customer_id
        )
      end
    end

    def ensure_customer_available!(customer_id)
      conflicting_subscription = Subscription
        .where(provider: Subscription::STRIPE_PROVIDER, external_customer_id: customer_id)
        .where.not(account_id: account.id)
        .exists?
      return unless conflicting_subscription

      raise InvalidAccountError, "Stripe Customer is associated with another account"
    end

    def stripe_metadata
      @stripe_metadata ||= {
        ACCOUNT_REFERENCE_KEY => account_reference,
        OPTION_KEY => option_key
      }.freeze
    end

    def account_reference
      @account_reference ||= StripeAccountReference.generate(account)
    end

    def customer_idempotency_key
      "boat-binder-customer-v1-#{Digest::SHA256.hexdigest("account-#{account.id}")}"
    end
  end
end
