module Billing
  class CheckoutsController < ApplicationController
    CHECKOUT_ERROR_MESSAGE = "We couldn't start Checkout right now. Please try again shortly."

    before_action :require_owner!
    before_action :set_billing_account, only: %i[show create]

    def show
      @billing_options = SubscriptionPlanCatalog.new.enabled_options
    rescue SubscriptionPlanCatalog::ConfigurationError
      @billing_options = []
      flash.now[:alert] = CHECKOUT_ERROR_MESSAGE
      render :show, status: :service_unavailable
    end

    def create
      checkout_session = StripeCheckoutSessionCreator.call(
        account: @billing_account,
        option_key: option_key_param,
        success_url: billing_checkout_success_url(**checkout_url_options),
        cancel_url: billing_checkout_cancel_url(**checkout_url_options)
      )

      redirect_to checkout_session.url, allow_other_host: true, status: :see_other
    rescue ActionController::ParameterMissing,
      StripeCheckoutSessionCreator::CheckoutError,
      StripeConfiguration::MissingConfigurationError,
      SubscriptionPlanCatalog::ConfigurationError
      @billing_options = available_billing_options
      flash.now[:alert] = CHECKOUT_ERROR_MESSAGE
      render :show, status: :unprocessable_entity
    end

    def success
    end

    def cancel
    end

    private

    def require_owner!
      deny_access! unless owner_user?
    end

    def set_billing_account
      @billing_account = StripeCheckoutAccountResolver.call(current_user)
    rescue StripeCheckoutAccountResolver::ResolutionError
      redirect_to root_path, alert: Authorization::ACCESS_DENIED_MESSAGE
    end

    def available_billing_options
      SubscriptionPlanCatalog.new.enabled_options
    rescue SubscriptionPlanCatalog::ConfigurationError
      []
    end

    def checkout_url_options
      Rails.application.config.action_mailer.default_url_options
    end

    def option_key_param
      option_key = params.require(:option_key)
      return option_key if option_key.is_a?(String)

      raise ActionController::ParameterMissing, :option_key
    end
  end
end
