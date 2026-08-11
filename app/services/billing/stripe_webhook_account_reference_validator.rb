module Billing
  class StripeWebhookAccountReferenceValidator
    def self.call(reference:, account_id:)
      new(reference: reference, account_id: account_id).call
    end

    def initialize(reference:, account_id:)
      @reference = reference
      @account_id = account_id
    end

    def call
      raise_association_error("missing_account_reference") if reference.blank?

      account = StripeAccountReference.find!(reference)
      return account if account.id == account_id

      raise_association_error("account_mismatch")
    rescue StripeAccountReference::InvalidReferenceError
      raise_association_error("invalid_account_reference")
    end

    private

    attr_reader :reference, :account_id

    def raise_association_error(code)
      raise StripeWebhookAssociationError, code
    end
  end
end
