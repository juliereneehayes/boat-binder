require "test_helper"

class AccountMembershipTest < ActiveSupport::TestCase
  setup do
    @account = create_account(name: "Transactional Email Eligibility")
  end

  test "verified active owner with active membership is transactionally email eligible" do
    membership = membership_for(verified_owner("verified-owner@example.test"))

    assert membership.transactional_email_eligible?
  end

  test "accepted-invitation active owner with active membership is transactionally email eligible" do
    owner = create_user(email: "accepted-owner@example.test", role: "owner")
    owner.update!(invitation_sent_at: 1.day.ago, invitation_accepted_at: Time.current)

    assert membership_for(owner).transactional_email_eligible?
  end

  test "active owner without a verification marker is not transactionally email eligible" do
    owner = create_user(email: "unverified-owner@example.test", role: "owner")

    assert_not membership_for(owner).transactional_email_eligible?
  end

  test "inactive owner is not transactionally email eligible" do
    owner = verified_owner("inactive-owner@example.test")
    owner.update!(active: false)

    assert_not membership_for(owner).transactional_email_eligible?
  end

  test "inactive membership is not transactionally email eligible" do
    membership = membership_for(verified_owner("inactive-membership@example.test"), active: false)

    assert_not membership.transactional_email_eligible?
  end

  test "non-owner is not transactionally email eligible" do
    captain = create_user(email: "verified-captain@example.test", role: "captain")
    captain.update!(email_verification_sent_at: 1.hour.ago, email_verified_at: Time.current)

    assert_not membership_for(captain).transactional_email_eligible?
  end

  test "owner without an email is not transactionally email eligible" do
    membership = membership_for(verified_owner("missing-email@example.test"))
    membership.user.email_address = ""

    assert_not membership.transactional_email_eligible?
  end

  private

  def membership_for(user, active: true)
    create_account_membership(user:, account: @account, active:)
  end

  def verified_owner(email)
    owner = create_user(email:, role: "owner")
    owner.update!(email_verification_sent_at: 1.hour.ago, email_verified_at: Time.current)
    owner
  end
end
