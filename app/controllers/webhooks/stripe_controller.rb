module Webhooks
  class StripeController < ApplicationController
    wrap_parameters false

    allow_unauthenticated_access only: :create
    skip_before_action :verify_authenticity_token, only: :create

    def create
      event = construct_event
      result = Billing::StripeWebhookProcessor.call(event)

      return head :ok if result.success?

      head :internal_server_error
    rescue JSON::ParserError
      Rails.logger.warn("Stripe webhook rejected malformed JSON payload")
      head :bad_request
    rescue Stripe::SignatureVerificationError
      Rails.logger.warn("Stripe webhook rejected invalid signature")
      head :bad_request
    rescue Billing::StripeConfiguration::MissingConfigurationError
      Rails.logger.error("Stripe webhook signing secret is not configured")
      head :bad_request
    end

    private

    def construct_event
      Stripe::Webhook.construct_event(
        request.raw_post,
        request.headers["Stripe-Signature"],
        Billing::StripeConfiguration.webhook_secret!
      )
    end
  end
end
