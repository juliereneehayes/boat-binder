require "test_helper"

class OwnerManagementTest < ActionDispatch::IntegrationTest
  test "captain creates and edits an owner with contact details and active status" do
    sign_in_as create_user(email: "admin-owner-timezone@example.test", role: "admin")

    assert_difference -> { Account.count }, 1 do
      assert_difference -> { Subscription.count }, 1 do
        post owners_path, params: {
          account: {
            name: "Solano Family",
            notes: "Prefers text updates.",
            active: "1",
            time_zone: "America/New_York"
          },
          contact: {
            name: "Maya Solano",
            email: "maya@example.test",
            phone: "555-0199"
          }
        }
      end
    end

    owner = Account.find_by!(name: "Solano Family")
    assert_redirected_to owner_path(owner)
    assert_equal "Maya Solano", owner.primary_contact.name
    assert_equal "America/New_York", owner.time_zone
    assert_equal "legacy", owner.subscription.plan
    assert_equal "active", owner.subscription.status

    patch owner_path(owner), params: {
      account: {
        name: "Solano Family",
        notes: "Inactive for winter.",
        active: "0",
        time_zone: "America/Chicago"
      },
      contact: {
        name: "Maya Solano",
        email: "maya.solano@example.test",
        phone: "555-0200"
      }
    }

    owner.reload
    assert_redirected_to owner_path(owner)
    assert_not owner.active?
    assert_equal "America/Chicago", owner.time_zone
    assert_equal "maya.solano@example.test", owner.primary_contact.email
  end

  test "owner form shows and preserves selected time zone after validation errors" do
    sign_in_as

    get new_owner_path

    assert_response :success
    assert_select "label[for='account_time_zone']", "Time zone"
    assert_select "select[name='account[time_zone]'] option[value='America/Los_Angeles'][selected]"

    assert_no_difference -> { Account.count } do
      post owners_path, params: {
        account: {
          name: "",
          active: "1",
          time_zone: "America/New_York"
        },
        contact: {
          name: "Maya Solano",
          email: "maya@example.test"
        }
      }
    end

    assert_response :unprocessable_entity
    assert_select "select[name='account[time_zone]'] option[value='America/New_York'][selected]"
  end

  test "owner creation failure after rollback rerenders create form action with submitted values" do
    original_default_attributes = Subscription.method(:default_local_attributes)
    Subscription.define_singleton_method(:default_local_attributes) do
      {
        plan: "legacy",
        status: "unsupported",
        provider: "local"
      }
    end
    sign_in_as create_user(email: "admin-rollback-form@example.test", role: "admin")

    assert_no_difference -> { Account.count } do
      assert_no_difference -> { Subscription.count } do
        assert_no_difference -> { Contact.count } do
          post owners_path, params: {
            account: {
              name: "Rollback Form Owner",
              notes: "These notes should stay.",
              active: "1",
              time_zone: "America/New_York"
            },
            contact: {
              name: "Rollback Contact",
              email: "rollback-contact@example.test",
              phone: "555-0190"
            }
          }
        end
      end
    end

    assert_response :unprocessable_entity
    assert_select "form[action='#{owners_path}']", count: 1
    assert_select "form[action*='/owners/']", count: 0
    assert_select "input[name='account[name]'][value='Rollback Form Owner']"
    assert_select "textarea[name='account[notes]']", text: "These notes should stay."
    assert_select "input[name='contact[name]'][value='Rollback Contact']"
    assert_select "input[name='contact[email]'][value='rollback-contact@example.test']"
    assert_includes response.body, "Status is not included in the list"
    assert_includes response.body, "Account could not be created with subscription state."
  ensure
    Subscription.define_singleton_method(:default_local_attributes, original_default_attributes)
  end

  test "inactive owners are hidden by default but can be included" do
    sign_in_as
    active_owner = create_account(name: "Active Owner")
    inactive_owner = create_account(name: "Inactive Owner")
    inactive_owner.update!(active: false)

    get owners_path
    assert_response :success
    assert_includes response.body, active_owner.name
    assert_not_includes response.body, inactive_owner.name

    get owners_path(include_inactive: "1")
    assert_response :success
    assert_includes response.body, inactive_owner.name
  end

  test "owner page lists linked owner users for the account only" do
    admin = create_user(email: "admin-linked-owners@example.test", role: "admin")
    account = create_account(name: "Elliott Family")
    other_account = create_account(name: "Harbor North")
    account.contacts.create!(name: "Manual Owner", email: "manual-owner@example.test", role: "Owner")
    linked_owner = create_user(email: "linked-owner@example.test", role: "owner", name: "Avery Elliott")
    pending_owner = User.create!(
      email_address: "pending-owner@example.test",
      role: "owner",
      active: false,
      invitation_sent_at: Time.current
    )
    other_owner = create_user(email: "other-account-owner@example.test", role: "owner", name: "Other Owner")
    create_account_membership(user: linked_owner, account: account)
    create_account_membership(user: pending_owner, account: account)
    create_account_membership(user: other_owner, account: other_account)
    sign_in_as admin

    get owner_path(account)

    assert_response :success
    assert_includes response.body, "Boat Binder account access"
    assert_includes response.body, "Avery Elliott"
    assert_includes response.body, "linked-owner@example.test"
    assert_includes response.body, "pending-owner@example.test"
    assert_includes response.body, "Invitation pending"
    assert_includes response.body, "Email recipient eligible"
    assert_includes response.body, "Not email eligible"
    assert_includes response.body, "Additional contact information"
    assert_includes response.body, "manual-owner@example.test"
    assert_not_includes response.body, "other-account-owner@example.test"
    assert_select "a[href='#{new_admin_user_path}']", text: "Invite owner user"
    assert_select "a[href='#{edit_admin_user_path(linked_owner)}']", text: "Manage user"
  end

  test "owner page renders empty account access and contact states" do
    admin = create_user(email: "admin-empty-owner-access@example.test", role: "admin")
    account = create_account(name: "No Contact Owner")
    sign_in_as admin

    get owner_path(account)

    assert_response :success
    assert_includes response.body, "No linked owner users yet."
    assert_includes response.body, "No additional contact information saved yet."
    assert_includes response.body, "Subscription"
    assert_includes response.body, "Legacy"
    assert_includes response.body, "Active"
    assert_includes response.body, "Local"
    assert_includes response.body, "No current Self Managed entitlement"
    assert_not_includes response.body, "Access eligible"
    assert_not_includes response.body, "Access paused"
    assert_includes response.body, "Not recorded"
  end

  test "owner page shows current access for qualifying Self Managed subscriptions" do
    now = Time.zone.local(2026, 8, 20, 12)
    admin = create_user(email: "admin-qualifying-subscription@example.test", role: "admin")
    account = create_account(name: "Qualifying Subscription Owner")
    sign_in_as admin

    travel_to now do
      qualify_self_managed_subscription(account, status: "active", now:)

      get owner_path(account)

      assert_response :success
      assert_includes response.body, "Self Managed access current"
      assert_not_includes response.body, "No current Self Managed entitlement"

      account.subscription.update!(status: "trialing")

      get owner_path(account)

      assert_response :success
      assert_includes response.body, "Self Managed access current"

      account.subscription.update!(status: "active", cancel_at_period_end: true)

      get owner_path(account)

      assert_response :success
      assert_includes response.body, "Self Managed access current"
      assert_includes response.body, "Cancels Sep 20, 2026 at 12:00 PM PDT"
    end
  end

  test "owner page describes an active canonical cancellation schedule as future" do
    now = Time.zone.local(2026, 8, 20, 12)
    admin = create_user(email: "admin-canonical-cancel-at@example.test", role: "admin")
    account = create_account(name: "Canonical Cancellation Owner")
    sign_in_as admin

    travel_to now do
      qualify_self_managed_subscription(account, status: "active", now:)
      account.subscription.update!(
        cancel_at_period_end: false,
        cancel_at: now + 2.weeks,
        canceled_at: now - 1.day
      )

      get owner_path(account)

      assert_response :success
      assert_includes response.body, "Cancels Sep 3, 2026 at 12:00 PM PDT"
      assert_not_includes response.body, "Canceled Aug 19, 2026"
    end
  end

  test "owner page shows no current entitlement for an expired Self Managed subscription" do
    now = Time.zone.local(2026, 8, 20, 12)
    admin = create_user(email: "admin-expired-subscription@example.test", role: "admin")
    account = create_account(name: "Expired Subscription Owner")
    sign_in_as admin

    travel_to now do
      qualify_self_managed_subscription(account, status: "active", now:)
      account.subscription.update!(current_period_ends_at: now)

      get owner_path(account)

      assert_response :success
      assert_includes response.body, "No current Self Managed entitlement"
      assert_not_includes response.body, "Self Managed access current"
    end
  end

  test "owner page shows entitlement badge and explanation when subscription is missing" do
    admin = create_user(email: "admin-missing-subscription@example.test", role: "admin")
    account = create_account(name: "Missing Subscription Owner")
    account.subscription.destroy!
    sign_in_as admin

    get owner_path(account)

    assert_response :success
    assert_includes response.body, "No current Self Managed entitlement"
    assert_includes response.body, "No local subscription record has been created yet."
    assert_not_includes response.body, "Access eligible"
    assert_not_includes response.body, "Access paused"
  end

  test "owner page renders partially populated external subscription state in account time zone" do
    admin = create_user(email: "admin-subscription-summary@example.test", role: "admin")
    account = create_account(name: "Subscription Summary Owner", time_zone: "America/New_York")
    account.subscription.update!(
      plan: "professional",
      status: "trialing",
      provider: "stripe",
      trial_ends_at: Time.utc(2026, 7, 15, 20, 0),
      current_period_ends_at: Time.utc(2026, 8, 15, 20, 0),
      cancel_at_period_end: true,
      last_synced_at: Time.utc(2026, 7, 12, 18, 30)
    )
    sign_in_as admin

    travel_to Time.utc(2026, 7, 12, 18, 30) do
      get owner_path(account)

      assert_response :success
      assert_includes response.body, "Professional"
      assert_includes response.body, "Trialing"
      assert_includes response.body, "Stripe"
      assert_includes response.body, "No current Self Managed entitlement"
      assert_includes response.body, "Cancels Aug 15, 2026 at 4:00 PM EDT"
      assert_includes response.body, "Jul 15, 2026 at 4:00 PM EDT"
      assert_includes response.body, "Aug 15, 2026 at 4:00 PM EDT"
      assert_includes response.body, "Jul 12, 2026 at 2:30 PM EDT"
    end
  end

  test "owner form clarifies manual contact information does not grant access" do
    sign_in_as create_user(email: "admin-owner-contact-copy@example.test", role: "admin")

    get new_owner_path

    assert_response :success
    assert_includes response.body, "Additional contact information"
    assert_includes response.body, "Use this for a contact who does not have Boat Binder access."
    assert_includes response.body, "Transactional emails are sent to linked active owner users when available."
  end
end
