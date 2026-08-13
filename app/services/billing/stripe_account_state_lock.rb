module Billing
  class StripeAccountStateLock
    def self.call(account:, attempt_id: nil)
      # Every Checkout and webhook transition locks Account -> Subscription -> Attempt.
      account.with_lock do
        subscription = Subscription.lock.find_by(account_id: account.id)
        attempt = if attempt_id
          BillingCheckoutAttempt.lock.find_by(id: attempt_id, account_id: account.id)
        end

        yield subscription, attempt
      end
    end
  end
end
