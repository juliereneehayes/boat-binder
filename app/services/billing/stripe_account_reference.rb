module Billing
  class StripeAccountReference
    PURPOSE = :stripe_billing_account

    class InvalidReferenceError < StandardError; end

    class << self
      def generate(account)
        account.signed_id(purpose: PURPOSE)
      end

      def find!(reference)
        account = find(reference)
        return account if account

        raise InvalidReferenceError, "Stripe account reference is invalid"
      end

      def find(reference)
        Account.find_signed(reference.to_s, purpose: PURPOSE)
      end
    end
  end
end
