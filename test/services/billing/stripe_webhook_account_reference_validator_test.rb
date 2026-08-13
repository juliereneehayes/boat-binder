require "test_helper"

module Billing
  class StripeWebhookAccountReferenceValidatorTest < ActiveSupport::TestCase
    setup do
      @account = create_account(name: "Webhook Reference Account")
    end

    test "returns the account for a valid matching signed reference" do
      reference = StripeAccountReference.generate(@account)

      assert_equal @account,
        StripeWebhookAccountReferenceValidator.call(reference: reference, account_id: @account.id)
    end

    test "rejects a missing account reference" do
      error = assert_raises(StripeWebhookAssociationError) do
        StripeWebhookAccountReferenceValidator.call(reference: nil, account_id: @account.id)
      end

      assert_equal "missing_account_reference", error.code
    end

    test "rejects an invalid signed account reference" do
      error = assert_raises(StripeWebhookAssociationError) do
        StripeWebhookAccountReferenceValidator.call(
          reference: "tampered-account-reference",
          account_id: @account.id
        )
      end

      assert_equal "invalid_account_reference", error.code
    end

    test "rejects a valid signed reference for another account" do
      other_account = create_account(name: "Other Webhook Reference Account")
      reference = StripeAccountReference.generate(other_account)

      error = assert_raises(StripeWebhookAssociationError) do
        StripeWebhookAccountReferenceValidator.call(reference: reference, account_id: @account.id)
      end

      assert_equal "account_mismatch", error.code
    end
  end
end
