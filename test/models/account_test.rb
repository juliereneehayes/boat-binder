require "test_helper"

class AccountTest < ActiveSupport::TestCase
  include AccountTimeZoneContext

  test "requires a valid account type" do
    account = Account.new(name: "Hayes", account_type: "vendor")

    assert_not account.valid?
    assert_includes account.errors[:account_type], "is not included in the list"
  end

  test "defaults to Pacific time" do
    account = Account.new(name: "Hayes", account_type: "client")

    assert account.valid?
    assert_equal "America/Los_Angeles", account.time_zone
  end

  test "requires a supported time zone" do
    account = Account.new(name: "Hayes", account_type: "client", time_zone: "Mars/Base")

    assert_not account.valid?
    assert_includes account.errors[:time_zone], "is not included in the list"
  end

  test "database default is Pacific time for existing-account backfills" do
    default = Account.columns_hash.fetch("time_zone").default

    assert_equal "America/Los_Angeles", default
  end

  test "time zone migration backfills null and blank values without the application model" do
    migration_source = Rails.root.join("db/migrate/20260712090000_add_time_zone_to_accounts.rb").read

    assert_not_includes migration_source, "Account.reset_column_information"
    refute_match(/\bAccount\.(where|update_all|find_each|all|find_by)/, migration_source)
    assert_includes migration_source, "UPDATE accounts"
    assert_includes migration_source, "WHERE time_zone IS NULL OR time_zone = ''"
  end

  test "account time zone uses daylight saving offsets" do
    account = create_account(time_zone: "America/Los_Angeles")

    winter_time = account_local_time(Time.utc(2026, 1, 15, 20, 0), account)
    summer_time = account_local_time(Time.utc(2026, 7, 15, 20, 0), account)

    assert_equal "-08:00", winter_time.formatted_offset
    assert_equal "-07:00", summer_time.formatted_offset
  end

  test "with account time zone scopes the block to the account zone" do
    account = create_account(time_zone: "America/New_York")

    Time.use_zone("UTC") do
      zone_name = with_account_time_zone(account) { Time.zone.name }

      assert_equal Time.find_zone("America/New_York").name, zone_name
    end
  end

  test "with account time zone restores the previous zone after the block" do
    account = create_account(time_zone: "America/New_York")

    Time.use_zone("UTC") do
      with_account_time_zone(account) { Time.zone.today }

      assert_equal Time.find_zone("UTC").name, Time.zone.name
    end
  end

  test "with account time zone requires a block" do
    account = create_account(time_zone: "America/New_York")

    error = assert_raises(ArgumentError) do
      with_account_time_zone(account)
    end

    assert_equal "block required", error.message
  end

  test "transactional owner recipient uses first active owner by membership order" do
    account = create_account(name: "Harbor North")
    captain = create_user(email: "account-captain-recipient@example.test", role: "captain")
    inactive_owner = create_user(email: "account-inactive-owner@example.test", role: "owner", active: false)
    first_owner = create_user(email: "account-first-owner@example.test", role: "owner")
    second_owner = create_user(email: "account-second-owner@example.test", role: "owner")

    create_account_membership(user: captain, account: account)
    create_account_membership(user: inactive_owner, account: account)
    first_membership = create_account_membership(user: first_owner, account: account)
    second_membership = create_account_membership(user: second_owner, account: account)

    assert_operator first_membership.id, :<, second_membership.id
    assert_equal first_owner, account.transactional_owner_recipient
    assert_equal "account-first-owner@example.test", account.transactional_recipient_email
  end

  test "transactional owner recipient skips inactive memberships and blank emails" do
    account = create_account(name: "Elliott Family")
    inactive_membership_owner = create_user(email: "inactive-membership-owner@example.test", role: "owner")
    blank_email_owner = create_user(email: "blank-email-owner@example.test", role: "owner")
    eligible_owner = create_user(email: "eligible-owner@example.test", role: "owner")
    blank_email_owner.update_column(:email_address, "")

    create_account_membership(user: inactive_membership_owner, account: account, active: false)
    create_account_membership(user: blank_email_owner, account: account)
    create_account_membership(user: eligible_owner, account: account)

    assert_equal eligible_owner, account.transactional_owner_recipient
    assert_equal "eligible-owner@example.test", account.transactional_recipient_email
  end

  test "verified transactional owner recipient stays within the account and follows membership order" do
    account = create_account(name: "Verified Harbor")
    other_account = create_account(name: "Other Verified Harbor")
    unverified_owner = create_user(email: "unverified-owner@example.test", role: "owner")
    first_verified_owner = verified_owner(email: "first-verified-owner@example.test")
    second_verified_owner = verified_owner(email: "second-verified-owner@example.test")
    other_owner = verified_owner(email: "other-account-owner@example.test")

    create_account_membership(user: unverified_owner, account:)
    first_membership = create_account_membership(user: first_verified_owner, account:)
    second_membership = create_account_membership(user: second_verified_owner, account:)
    create_account_membership(user: other_owner, account: other_account)

    assert_operator first_membership.id, :<, second_membership.id
    assert_equal first_verified_owner, account.verified_transactional_owner_recipient
  end

  test "accepted invitation qualifies an owner as a verified transactional recipient" do
    account = create_account(name: "Invitation Verified Harbor")
    owner = create_user(email: "accepted-owner@example.test", role: "owner")
    owner.update!(invitation_sent_at: 1.day.ago, invitation_accepted_at: Time.current)
    create_account_membership(user: owner, account:)

    assert_equal owner, account.verified_transactional_owner_recipient
  end

  test "transactional recipient falls back to manual primary contact only when no owner user is eligible" do
    account = create_account(name: "Marisol Trust")
    account.contacts.create!(name: "Manual Contact", email: "manual-owner@example.test", role: "Owner")
    inactive_owner = create_user(email: "inactive-fallback-owner@example.test", role: "owner", active: false)
    captain = create_user(email: "captain-fallback@example.test", role: "captain")

    create_account_membership(user: inactive_owner, account: account)
    create_account_membership(user: captain, account: account)

    assert_nil account.transactional_owner_recipient
    assert_equal "manual-owner@example.test", account.transactional_recipient_email
  end

  test "transactional recipient is blank when no owner user or manual contact email exists" do
    account = create_account(name: "No Recipient Owner")

    assert_nil account.transactional_owner_recipient
    assert_nil account.transactional_recipient_email
  end

  test "owns contacts and assets" do
    account = create_account
    contact = account.contacts.create!(name: "Avery Elliott", role: "Owner")
    asset = account.assets.create!(name: "Blue Meridian", asset_type: "vessel")

    assert_equal [ contact ], account.contacts.to_a
    assert_equal [ asset ], account.assets.to_a
    assert_equal [ asset ], account.vessel_assets.to_a
  end

  test "can be inactive without removing vessels" do
    account = create_account
    asset = account.assets.create!(name: "Blue Meridian", asset_type: "vessel")

    account.update!(active: false)

    assert_equal "Inactive", account.status_label
    assert_includes account.assets, asset
  end


  private

  def verified_owner(email:)
    owner = create_user(email:, role: "owner")
    owner.update!(email_verification_sent_at: 1.hour.ago, email_verified_at: Time.current)
    owner
  end
end
