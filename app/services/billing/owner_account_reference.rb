module Billing
  class OwnerAccountReference
    PURPOSE = :owner_lifecycle_account

    class InvalidReferenceError < StandardError; end

    class << self
      def generate(account)
        account.signed_id(purpose: PURPOSE)
      end

      def find!(reference)
        account = Account.find_signed(reference.to_s, purpose: PURPOSE)
        return account if account

        raise InvalidReferenceError, "Owner account reference is invalid"
      end
    end
  end
end
