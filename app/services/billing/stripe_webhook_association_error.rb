module Billing
  class StripeWebhookAssociationError < StandardError
    attr_reader :code

    def initialize(code)
      @code = code
      super("Stripe webhook association could not be verified")
    end
  end
end
