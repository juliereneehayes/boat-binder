require "test_helper"

class UserOwnerLimitTest < ActiveSupport::TestCase
  test "direct role changes cannot create a second active Owner on Self Managed" do
    account = create_account(name: "Direct Owner role change")
    existing_owner = create_user(email: "direct-existing-owner@example.test", role: "owner")
    candidate = create_user(email: "direct-owner-candidate@example.test", role: "captain")
    create_account_membership(user: existing_owner, account: account, access_level: "editor")
    create_account_membership(user: candidate, account: account, access_level: "read_only")
    qualify_self_managed_subscription(account)

    candidate.role = "owner"

    assert_not candidate.save
    assert_includes candidate.errors[:role], Billing::OwnerUserLimit::ERROR_MESSAGE
    assert candidate.reload.captain?
  end
end
