module Billing
  class StripeWebhookStaleEvent < StandardError
    def initialize
      super("Stripe webhook lifecycle event is stale")
    end
  end
end
