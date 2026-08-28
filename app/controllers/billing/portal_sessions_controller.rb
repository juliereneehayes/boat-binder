module Billing
  class PortalSessionsController < ApplicationController
    PORTAL_ERROR_MESSAGE = "We couldn't open billing management right now. Please try again shortly."

    before_action :require_owner!
    before_action :set_billing_account

    def create
      portal_session = StripePortalSessionCreator.call(
        account: @billing_account,
        return_url: root_url(**application_url_options)
      )

      request.set_header(
        "action_dispatch.redirect_filter",
        [ StripePortalSessionCreator::PORTAL_HOST ]
      )
      redirect_to portal_session.url, allow_other_host: true, status: :see_other
    rescue StripePortalSessionCreator::PortalError,
      StripeConfiguration::MissingConfigurationError
      redirect_to root_path, alert: PORTAL_ERROR_MESSAGE, status: :see_other
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

    def application_url_options
      Rails.application.config.action_mailer.default_url_options
    end
  end
end
