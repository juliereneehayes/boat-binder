require "test_helper"

class ManagedServiceRelationshipTest < ActiveSupport::TestCase
  test "only an active relationship on an active account is effective" do
    account = create_account(name: "Managed Service Account")

    assert_not ManagedServiceRelationship.effective_for?(account)

    relationship = account.create_managed_service_relationship!(active: true)
    assert ManagedServiceRelationship.effective_for?(account)

    relationship.update!(active: false)
    assert_not ManagedServiceRelationship.effective_for?(account)

    relationship.update!(active: true)
    account.update!(active: false)
    assert_not ManagedServiceRelationship.effective_for?(account)
  end

  test "subscription state does not establish managed service authority" do
    account = create_account(name: "Unrelated Subscription Account")
    account.subscription.update!(plan: "professional", status: "active")

    assert_not ManagedServiceRelationship.effective_for?(account)
  end

  test "an account can have only one managed service relationship" do
    account = create_account(name: "Unique Managed Service Account")
    account.create_managed_service_relationship!(active: true)

    duplicate = ManagedServiceRelationship.new(account:, active: true)

    assert_not duplicate.valid?
    assert_includes duplicate.errors[:account_id], "has already been taken"
  end
end
