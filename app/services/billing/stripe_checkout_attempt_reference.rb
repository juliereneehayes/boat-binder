module Billing
  class StripeCheckoutAttemptReference
    PURPOSE = :stripe_checkout_attempt

    class InvalidReferenceError < StandardError; end

    class << self
      def generate(attempt)
        attempt.signed_id(purpose: PURPOSE)
      end

      def find!(reference)
        attempt = BillingCheckoutAttempt.find_signed(reference.to_s, purpose: PURPOSE)
        return attempt if attempt

        raise InvalidReferenceError, "Stripe Checkout attempt reference is invalid"
      end
    end
  end
end
