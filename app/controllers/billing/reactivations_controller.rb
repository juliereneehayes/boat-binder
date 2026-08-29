module Billing
  class ReactivationsController < ApplicationController
    REACTIVATION_ERROR_MESSAGE = "We couldn't start reactivation right now. Please try again shortly."

    before_action :require_owner!
    before_action :set_billing_account

    def create
      checkout_session = StripeTerminalReactivationSessionCreator.call(
        account: @billing_account,
        option_key: option_key_param,
        success_url: billing_checkout_success_url(**checkout_url_options),
        cancel_url: billing_checkout_cancel_url(**checkout_url_options)
      )

      request.set_header(
        "action_dispatch.redirect_filter",
        [ StripeCheckoutSessionCreator::CHECKOUT_HOST ]
      )
      redirect_to checkout_session.url, allow_other_host: true, status: :see_other
    rescue ActionController::ParameterMissing,
      StripeTerminalReactivationSessionCreator::ReactivationError,
      StripeConfiguration::MissingConfigurationError,
      SubscriptionPlanCatalog::ConfigurationError
      redirect_to root_path, alert: REACTIVATION_ERROR_MESSAGE, status: :see_other
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
