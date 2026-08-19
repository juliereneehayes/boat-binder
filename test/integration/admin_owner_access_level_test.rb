require "test_helper"

class AdminOwnerAccessLevelTest < ActionDispatch::IntegrationTest
  setup do
    ActionMailer::Base.deliveries.clear
    @admin = create_user(email: "access-level-admin@example.test", role: "admin")
    @account = create_account(name: "Access Level Account")
    @other_account = create_account(name: "Second Access Level Account")
    sign_in_as @admin
  end

  teardown do
    ActionMailer::Base.deliveries.clear
  end

  test "creating an owner without an explicit level defaults to read only" do
    post admin_users_path, params: { user: owner_params(email_address: "default-level@example.test") }

    membership = User.find_by!(email_address: "default-level@example.test").account_memberships.find_by!(account: @account)
    assert_redirected_to admin_users_path
    assert_equal AccountMembership::DEFAULT_ACCESS_LEVEL, membership.access_level
  end

  test "creating an owner with explicit editor access persists editor" do
    post admin_users_path, params: {
      user: owner_params(
        email_address: "editor-level@example.test",
        account_access_levels: { @account.id.to_s => "editor" }
      )
    }

    membership = User.find_by!(email_address: "editor-level@example.test").account_memberships.find_by!(account: @account)
    assert_redirected_to admin_users_path
    assert_equal "editor", membership.access_level
  end

  test "inviting an owner preserves the selected editor access" do
    assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
      post admin_users_path, params: {
        user: owner_params(
          email_address: "invited-editor@example.test",
          send_invitation: "1",
          password: "",
          password_confirmation: "",
          account_access_levels: { @account.id.to_s => "editor" }
        )
      }
    end

    invited_user = User.find_by!(email_address: "invited-editor@example.test")
    assert invited_user.invitation_pending?
    assert_equal "editor", invited_user.account_memberships.find_by!(account: @account).access_level
  end

  test "editing an editor membership without a submitted level preserves editor" do
    owner = owner_with_membership(access_level: "editor")

    patch admin_user_path(owner), params: { user: owner_update_params(owner) }

    assert_redirected_to admin_users_path
    assert_equal "editor", owner.account_memberships.find_by!(account: @account).access_level
  end

  test "admin can change owner access between read only and editor" do
    owner = owner_with_membership(access_level: "editor")

    patch admin_user_path(owner), params: {
      user: owner_update_params(owner, account_access_levels: { @account.id.to_s => "read_only" })
    }
    assert_equal "read_only", owner.account_memberships.find_by!(account: @account).reload.access_level

    patch admin_user_path(owner), params: {
      user: owner_update_params(owner, account_access_levels: { @account.id.to_s => "editor" })
    }
    assert_equal "editor", owner.account_memberships.find_by!(account: @account).reload.access_level
  end

  test "removing an account deactivates rather than deletes its membership" do
    owner = owner_with_membership(access_level: "editor")
    membership = owner.account_memberships.find_by!(account: @account)

    assert_no_difference -> { AccountMembership.count } do
      patch admin_user_path(owner), params: { user: owner_update_params(owner, account_ids: []) }
    end

    assert_redirected_to admin_users_path
    assert_not membership.reload.active?
    assert_equal "editor", membership.access_level
  end

  test "selecting an inactive membership reactivates it without creating a duplicate" do
    owner = owner_with_membership(access_level: "editor", active: false)

    assert_no_difference -> { AccountMembership.count } do
      patch admin_user_path(owner), params: { user: owner_update_params(owner) }
    end

    membership = owner.account_memberships.find_by!(account: @account)
    assert membership.active?
    assert_equal "editor", membership.access_level
  end

  test "invalid access levels reject all user and membership changes transactionally" do
    owner = owner_with_membership(access_level: "read_only")

    patch admin_user_path(owner), params: {
      user: owner_update_params(
        owner,
        name: "Should Roll Back",
        account_access_levels: { @account.id.to_s => "administrator" }
      )
    }

    assert_response :unprocessable_entity
    assert_includes response.body, "Owner account access has an invalid access level."
    assert_not_includes response.body, "administrator"
    assert_not_equal "Should Roll Back", owner.reload.name
    assert_equal "read_only", owner.account_memberships.find_by!(account: @account).reload.access_level
  end

  test "malformed account ids are rejected without creating a user" do
    assert_no_difference -> { User.count } do
      assert_no_difference -> { AccountMembership.count } do
        post admin_users_path, params: {
          user: owner_params(email_address: "malformed-account@example.test", account_ids: [ "#{@account.id}x" ])
        }
      end
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "Owner account access has an invalid account selection."
  end

  test "inactive accounts are rejected without deactivating valid memberships" do
    owner = owner_with_membership(access_level: "editor")
    inactive_account = create_account(name: "Inactive Access Level Account")
    inactive_account.update!(active: false)

    patch admin_user_path(owner), params: {
      user: owner_update_params(
        owner,
        account_ids: [ @account.id, inactive_account.id ],
        account_access_levels: {
          @account.id.to_s => "read_only",
          inactive_account.id.to_s => "editor"
        }
      )
    }

    assert_response :unprocessable_entity
    assert_includes response.body, "Owner account access includes an unavailable account."
    membership = owner.account_memberships.find_by!(account: @account).reload
    assert membership.active?
    assert_equal "editor", membership.access_level
    assert_not owner.account_memberships.exists?(account: inactive_account)
  end

  test "internal users ignore owner membership parameters and deactivate historical memberships" do
    owner = owner_with_membership(access_level: "editor")

    patch admin_user_path(owner), params: {
      user: owner_update_params(
        owner,
        role: "captain",
        account_access_levels: { @account.id.to_s => "editor" }
      )
    }

    assert_redirected_to admin_users_path
    assert owner.reload.captain?
    assert_empty owner.account_memberships.active
  end

  test "non admins cannot change owner membership levels" do
    owner = owner_with_membership(access_level: "read_only")
    captain = create_user(email: "access-level-captain@example.test", role: "captain")
    delete session_path
    sign_in_as captain

    patch admin_user_path(owner), params: {
      user: owner_update_params(owner, account_access_levels: { @account.id.to_s => "editor" })
    }

    assert_access_denied_redirect
    assert_equal "read_only", owner.account_memberships.find_by!(account: @account).reload.access_level
  end

  test "form and index explain and display owner access levels" do
    owner = owner_with_membership(access_level: "editor")
    inactive_membership = create_account_membership(
      user: owner,
      account: @other_account,
      access_level: "read_only",
      active: false
    )

    get edit_admin_user_path(owner)

    assert_response :success
    assert_includes response.body, "Read only"
    assert_includes response.body, "can view account and vessel records but cannot make owner-permitted changes"
    assert_includes response.body, "can make changes already authorized for owner editors"
    assert_select "input[name='user[account_ids][]'][value='#{@account.id}'][checked]"
    assert_select "select[name='user[account_access_levels][#{@account.id}]'] option[value='editor'][selected]"
    assert_select "select[name='user[account_access_levels][#{@other_account.id}]'][disabled]"

    get admin_users_path

    assert_includes response.body, "Manage users and owner account access."
    assert_select "span", text: "#{@account.name} — Editor"
    assert_select "span", text: "#{inactive_membership.account.name} — Read only (inactive)"
  end

  test "validation errors preserve trusted account selections and access levels" do
    existing_user = create_user(email: "duplicate-access-level@example.test", role: "owner")

    post admin_users_path, params: {
      user: owner_params(
        email_address: existing_user.email_address,
        account_access_levels: { @account.id.to_s => "editor" }
      )
    }

    assert_response :unprocessable_entity
    assert_select "input[name='user[account_ids][]'][value='#{@account.id}'][checked]"
    assert_select "select[name='user[account_access_levels][#{@account.id}]'] option[value='editor'][selected]"
  end

  test "admin and captain forms disable owner membership controls" do
    captain = create_user(email: "disabled-access-level-captain@example.test", role: "captain")

    get edit_admin_user_path(captain)

    assert_response :success
    assert_select "input[name='user[account_ids][]'][disabled]", count: 2
    assert_select "select[name^='user[account_access_levels]'][disabled]", count: 2
  end

  private

  def owner_params(overrides = {})
    {
      name: "Owner Access User",
      email_address: "owner-access@example.test",
      role: "owner",
      active: "1",
      send_invitation: "0",
      password: "password",
      password_confirmation: "password",
      account_ids: [ @account.id ]
    }.merge(overrides)
  end

  def owner_update_params(owner, overrides = {})
    {
      name: owner.name,
      email_address: owner.email_address,
      role: "owner",
      active: "1",
      password: "",
      password_confirmation: "",
      account_ids: [ @account.id ]
    }.merge(overrides)
  end

  def owner_with_membership(access_level:, active: true)
    owner = create_user(
      email: "managed-owner-#{SecureRandom.hex(4)}@example.test",
      role: "owner",
      name: "Managed Owner"
    )
    create_account_membership(user: owner, account: @account, access_level: access_level, active: active)
    owner
  end
end
