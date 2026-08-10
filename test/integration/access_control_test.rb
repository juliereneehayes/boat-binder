require "test_helper"

class AccessControlTest < ActionDispatch::IntegrationTest
  test "admin can access owner records across accounts and manage users" do
    setup_access_records
    sign_in_as @admin

    get vessel_path(@owner_a_vessel)
    assert_response :success
    assert_includes response.body, @owner_a_vessel.name

    get vessel_path(@owner_b_vessel)
    assert_response :success
    assert_includes response.body, @owner_b_vessel.name

    get admin_users_path
    assert_response :success
    assert_includes response.body, @owner_a_user.email_address

    new_owner = create_account(name: "Solano Family")
    assert_difference -> { User.count }, 1 do
      post admin_users_path, params: {
        user: {
          name: "Maya Solano",
          email_address: "maya@example.test",
          role: "owner",
          active: "1",
          password: "password",
          password_confirmation: "password",
          account_ids: [ new_owner.id ]
        }
      }
    end

    created_user = User.find_by!(email_address: "maya@example.test")
    assert_redirected_to admin_users_path
    assert created_user.owner?
    assert_equal [ new_owner.id ], created_user.account_memberships.active.pluck(:account_id)
  end

  test "captain can access and manage operational records" do
    setup_access_records
    sign_in_as @captain

    get vessel_path(@owner_b_vessel)
    assert_response :success
    assert_includes response.body, @owner_b_vessel.name

    assert_difference -> { Reminder.count }, 1 do
      post reminders_path, params: {
        reminder: {
          asset_id: @owner_b_vessel.id,
          title: "Replace zincs",
          due_date: Date.tomorrow,
          reminder_type: "maintenance"
        }
      }
    end

    assert_redirected_to reminders_path
  end

  test "owner sees only associated records" do
    setup_access_records
    sign_in_as @owner_a_user

    get vessels_path
    assert_response :success
    assert_includes response.body, @owner_a_vessel.name
    assert_not_includes response.body, @owner_b_vessel.name
    assert_not_includes response.body, "Add vessel"

    get documents_path
    assert_response :success
    assert_includes response.body, @owner_a_document.title
    assert_not_includes response.body, @owner_b_document.title

    get reminders_path
    assert_response :success
    assert_includes response.body, @owner_a_reminder.title
    assert_not_includes response.body, @owner_b_reminder.title
    assert_not_includes response.body, "Mark complete"

    get service_visits_path
    assert_response :success
    assert_not_includes response.body, @owner_b_visit.summary
    assert_not_includes response.body, @owner_b_vessel.name
  end

  test "subscription status does not change existing owner access in phase one" do
    setup_access_records
    @owner_a_account.subscription.update!(status: "suspended")
    sign_in_as @owner_a_user

    get vessel_path(@owner_a_vessel)

    assert_response :success
    assert_includes response.body, @owner_a_vessel.name
  end

  test "owner cannot access another owner's direct object URLs" do
    setup_access_records
    sign_in_as @owner_a_user

    get vessel_path(@owner_b_vessel)
    assert_response :not_found

    get vessel_service_visit_path(@owner_b_vessel, @owner_b_visit)
    assert_response :not_found

    get edit_vessel_path(@owner_b_vessel)
    assert_response :not_found

    get vessel_path(@owner_a_vessel)
    assert_response :success
    assert_includes response.body, @owner_a_document.title
    assert_not_includes response.body, @owner_b_document.title
  end

  test "owner cannot create update or delete operational records" do
    setup_access_records
    sign_in_as @owner_a_user

    assert_no_difference -> { Asset.count } do
      post vessels_path, params: {
        asset: {
          account_id: @owner_a_account.id,
          name: "Owner Edit",
          active: "1"
        }
      }
    end
    assert_access_denied_redirect

    patch vessel_path(@owner_a_vessel), params: {
      asset: {
        name: "Renamed by Owner",
        account_id: @owner_a_account.id
      }
    }
    assert_access_denied_redirect
    assert_not_equal "Renamed by Owner", @owner_a_vessel.reload.name

    assert_no_difference -> { Document.count } do
      delete document_path(@owner_a_document)
    end
    assert_access_denied_redirect
  end

  test "admin user management redirects non-admin users gracefully" do
    setup_access_records

    sign_in_as @captain
    get admin_users_path
    assert_access_denied_redirect

    sign_in_as @owner_a_user
    get admin_users_path
    assert_access_denied_redirect
  end

  test "admin users can reach admin user management from users redirect" do
    setup_access_records
    sign_in_as @admin

    get "/users"
    assert_redirected_to admin_users_path

    follow_redirect!
    assert_response :success
    assert_includes response.body, @owner_a_user.email_address
  end

  test "non-admin users cannot create or update admin-managed users" do
    setup_access_records

    sign_in_as @captain
    assert_no_difference -> { User.count } do
      post admin_users_path, params: {
        user: {
          name: "Created by Captain",
          email_address: "captain-created@example.test",
          role: "owner",
          active: "1",
          password: "password",
          password_confirmation: "password",
          account_ids: [ @owner_a_account.id ]
        }
      }
    end
    assert_access_denied_redirect

    sign_in_as @owner_a_user
    patch admin_user_path(@owner_b_user), params: {
      user: {
        name: "Owner Escalation",
        email_address: @owner_b_user.email_address,
        role: "admin",
        active: "1",
        password: "",
        password_confirmation: ""
      }
    }
    assert_access_denied_redirect
    assert_not @owner_b_user.reload.admin?
    assert_not_equal "Owner Escalation", @owner_b_user.name
  end

  test "login page does not expose demo credentials" do
    get new_session_path

    assert_response :success
    assert_not_includes response.body, "Demo captain:"
    assert_not_includes response.body, "captain@hayesyacht.test / password"
  end

  test "inactive users see generic login failure and cannot sign in" do
    inactive_user = create_user(email: "inactive@example.test", active: false)

    assert_no_difference -> { Session.count } do
      post session_path, params: {
        email_address: inactive_user.email_address,
        password: "password"
      }
    end

    assert_redirected_to new_session_path
    follow_redirect!
    assert_response :success
    assert_select "div", text: Authentication::GENERIC_LOGIN_FAILURE_MESSAGE
    assert_not_includes response.body.downcase, "inactive"
  end

  test "active users can still sign in successfully" do
    active_user = create_user(email: "active-login@example.test", active: true)

    assert_difference -> { Session.count }, 1 do
      post session_path, params: {
        email_address: active_user.email_address,
        password: "password"
      }
    end

    assert_redirected_to root_path
    assert_equal active_user, Session.order(:created_at).last.user
  end

  test "layout includes svg favicon link" do
    get new_session_path

    assert_response :success
    assert_select "link[rel='icon'][type='image/svg+xml']"
  end

  test "header and dashboard show logged in user role and greeting" do
    setup_access_records

    sign_in_as @admin
    get root_path

    assert_response :success
    assert_includes response.body, "Admin User"
    assert_includes response.body, "Admin"
    assert_includes response.body, "Hello Admin"
    assert_includes response.body, "Admin Dashboard"
    assert_select "a", text: "Owners"

    sign_in_as @captain
    get root_path

    assert_response :success
    assert_includes response.body, "Captain User"
    assert_includes response.body, "Captain"
    assert_includes response.body, "Hello Captain"
    assert_includes response.body, "Captain Dashboard"
    assert_select "a", text: "Owners"

    sign_in_as @owner_a_user
    get root_path

    assert_response :success
    assert_includes response.body, "Avery Elliott"
    assert_includes response.body, "Owner"
    assert_includes response.body, "Hello Avery"
    assert_includes response.body, "Owner Dashboard"
    assert_select "a", text: "Owners", count: 0
  end

  test "admin mobile and desktop navigation includes users link and mobile sign out" do
    setup_access_records
    sign_in_as @admin

    get root_path

    assert_response :success
    assert_select "aside.fixed a[href='#{admin_users_path}']", text: "Users"
    assert_select "nav.fixed a[href='#{admin_users_path}']", text: "Users"
    assert_select "nav.fixed form[action='#{session_path}'] button", text: "Sign out"
  end

  test "captain and owner navigation does not include users link" do
    setup_access_records

    sign_in_as @captain
    get root_path

    assert_response :success
    assert_select "a[href='#{admin_users_path}']", count: 0
    assert_select "nav.fixed form[action='#{session_path}'] button", text: "Sign out"

    sign_in_as @owner_a_user
    get root_path

    assert_response :success
    assert_select "a[href='#{admin_users_path}']", count: 0
    assert_select "nav.fixed form[action='#{session_path}'] button", text: "Sign out"
  end

  test "admin and captain user forms show global account access as checked and disabled" do
    setup_access_records
    sign_in_as @admin

    get edit_admin_user_path(@admin)
    assert_response :success
    assert_includes response.body, "Admin and captain users have access to all vessels automatically."
    assert_select "input[name='user[account_ids][]'][checked='checked'][disabled='disabled']", count: 2

    get edit_admin_user_path(@captain)
    assert_response :success
    assert_includes response.body, "Admin and captain users have access to all vessels automatically."
    assert_select "input[name='user[account_ids][]'][checked='checked'][disabled='disabled']", count: 2
  end

  test "owner user form shows only explicit account access as editable" do
    setup_access_records
    sign_in_as @admin

    get edit_admin_user_path(@owner_a_user)

    assert_response :success
    assert_select "input[name='user[account_ids][]'][disabled='disabled']", count: 0
    assert_select "input[name='user[account_ids][]'][checked='checked']", count: 1
    assert_select "input[name='user[account_ids][]'][value='#{@owner_a_account.id}'][checked='checked']"
    assert_select "input[name='user[account_ids][]'][value='#{@owner_b_account.id}'][checked='checked']", count: 0
  end

  test "admin user forms use the same active account list as owners index" do
    setup_access_records
    internal_account = create_account(name: "Hayes Yacht Company", account_type: "internal")
    inactive_account = create_account(name: "Carter and Vale")
    inactive_account.update!(active: false)
    expected_account_ids = Account.active.ordered.pluck(:id)

    sign_in_as @admin

    get owners_path
    assert_response :success
    expected_account_ids.each do |account_id|
      assert_includes response.body, Account.find(account_id).name
    end
    assert_not_includes response.body, inactive_account.name

    get new_admin_user_path
    assert_response :success
    assert_equal expected_account_ids, admin_user_form_account_ids
    assert_includes response.body, internal_account.name
    assert_not_includes response.body, inactive_account.name

    get edit_admin_user_path(@owner_a_user)
    assert_response :success
    assert_equal expected_account_ids, admin_user_form_account_ids
    assert_includes response.body, internal_account.name
    assert_not_includes response.body, inactive_account.name

    assert_no_difference -> { @owner_a_user.account_memberships.where(account: inactive_account).count } do
      patch admin_user_path(@owner_a_user), params: {
        user: {
          name: @owner_a_user.name,
          email_address: @owner_a_user.email_address,
          role: "owner",
          active: "1",
          password: "",
          password_confirmation: "",
          account_ids: [ @owner_a_account.id, inactive_account.id ]
        }
      }
    end
  end

  test "internal user account access params do not create memberships" do
    setup_access_records
    sign_in_as @admin

    assert_no_difference -> { @captain.account_memberships.reload.count } do
      patch admin_user_path(@captain), params: {
        user: {
          name: @captain.name,
          email_address: @captain.email_address,
          role: "captain",
          active: "1",
          password: "",
          password_confirmation: "",
          account_ids: [ @owner_a_account.id, @owner_b_account.id ]
        }
      }
    end

    assert_redirected_to admin_users_path
    assert_empty @captain.account_memberships.active
  end

  test "admin updates owner account access with blank password fields" do
    setup_access_records
    sign_in_as @admin

    patch admin_user_path(@owner_a_user), params: {
      user: {
        name: "Avery Elliott",
        email_address: @owner_a_user.email_address,
        role: "owner",
        active: "1",
        password: "",
        password_confirmation: "",
        account_ids: [ @owner_b_account.id ]
      }
    }

    assert_redirected_to admin_users_path
    assert_equal [ @owner_b_account.id ], @owner_a_user.account_memberships.reload.active.pluck(:account_id)

    delete session_path
    sign_in_as @owner_a_user
    assert_redirected_to root_path
  end

  test "admin edit user renders password mismatch validation without syncing memberships" do
    setup_access_records
    sign_in_as @admin

    patch admin_user_path(@owner_a_user), params: {
      user: {
        name: "Avery Elliott",
        email_address: @owner_a_user.email_address,
        role: "owner",
        active: "1",
        password: "new-password",
        password_confirmation: "different-password",
        account_ids: [ @owner_b_account.id ]
      }
    }

    assert_response :unprocessable_entity
    assert_includes response.body, "Password confirmation"
    assert_equal [ @owner_a_account.id ], @owner_a_user.account_memberships.reload.active.pluck(:account_id)
  end

  test "admin user management rejects invalid role values" do
    setup_access_records
    sign_in_as @admin

    assert_no_difference -> { User.count } do
      post admin_users_path, params: {
        user: {
          name: "Invalid Role",
          email_address: "invalid-role@example.test",
          role: "super_admin",
          active: "1",
          password: "password",
          password_confirmation: "password",
          account_ids: [ @owner_a_account.id ]
        }
      }
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "Role is not included in the list"

    patch admin_user_path(@owner_a_user), params: {
      user: {
        name: @owner_a_user.name,
        email_address: @owner_a_user.email_address,
        role: "super_admin",
        active: "1",
        password: "",
        password_confirmation: ""
      }
    }

    assert_response :unprocessable_entity
    assert_includes response.body, "Role is not included in the list"
    assert_equal "owner", @owner_a_user.reload.role
  end

  test "admins can assign only valid roles" do
    setup_access_records
    sign_in_as @admin

    User::ROLES.each do |role|
      assert_difference -> { User.count }, 1 do
        post admin_users_path, params: {
          user: {
            name: "#{role.humanize} User",
            email_address: "#{role}-created@example.test",
            role: role,
            active: "1",
            password: "password",
            password_confirmation: "password",
            account_ids: [ @owner_a_account.id ]
          }
        }
      end

      created_user = User.find_by!(email_address: "#{role}-created@example.test")
      assert_equal role, created_user.role
      assert_redirected_to admin_users_path
    end
  end

  test "owner restricted direct access redirects gracefully without exposing records" do
    setup_access_records
    sign_in_as @owner_a_user

    get owners_path
    assert_access_denied_redirect
    assert_not_includes response.body, @owner_b_account.name
    assert_not_includes response.body, @owner_b_vessel.name

    get accounts_path
    assert_access_denied_redirect
    assert_not_includes response.body, @owner_b_account.name
    assert_not_includes response.body, @owner_b_vessel.name

    get owner_path(@owner_a_account)
    assert_access_denied_redirect
  end

  test "admin and captain can access owner and account indexes" do
    setup_access_records

    sign_in_as @admin
    get owners_path
    assert_response :success
    assert_includes response.body, @owner_a_account.name
    assert_includes response.body, @owner_b_account.name

    get accounts_path
    assert_response :success
    assert_includes response.body, @owner_a_account.name
    assert_includes response.body, @owner_b_account.name

    sign_in_as @captain
    get owners_path
    assert_response :success
    assert_includes response.body, @owner_a_account.name
    assert_includes response.body, @owner_b_account.name

    get accounts_path
    assert_response :success
    assert_includes response.body, @owner_a_account.name
    assert_includes response.body, @owner_b_account.name
  end

  private

  def setup_access_records
    @admin = create_user(email: "admin@example.test", role: "admin", name: "Admin User")
    @captain = create_user(email: "captain-access@example.test", role: "captain", name: "Captain User")

    @owner_a_account = create_account(name: "Elliott Family")
    @owner_b_account = create_account(name: "Harbor North")
    @owner_a_vessel = create_vessel(account: @owner_a_account, name: "Blue Meridian")
    @owner_b_vessel = create_vessel(account: @owner_b_account, name: "Tide Runner")

    @owner_a_user = create_user(email: "owner-a@example.test", role: "owner", name: "Avery Elliott")
    @owner_b_user = create_user(email: "owner-b@example.test", role: "owner", name: "Noah Pierce")
    create_account_membership(user: @owner_a_user, account: @owner_a_account)
    create_account_membership(user: @owner_b_user, account: @owner_b_account)

    @owner_a_document = @owner_a_vessel.documents.create!(
      account: @owner_a_account,
      title: "A registration",
      document_type: "registration"
    )
    @owner_b_document = @owner_b_vessel.documents.create!(
      account: @owner_b_account,
      title: "B registration",
      document_type: "registration"
    )

    @owner_a_reminder = @owner_a_vessel.reminders.create!(
      title: "A zincs",
      due_date: Date.tomorrow,
      reminder_type: "maintenance",
      status: "pending"
    )
    @owner_b_reminder = @owner_b_vessel.reminders.create!(
      title: "B zincs",
      due_date: Date.tomorrow,
      reminder_type: "maintenance",
      status: "pending"
    )

    @owner_b_visit = @owner_b_vessel.service_visits.create!(
      performed_by_user: @captain,
      visit_date: Date.current,
      summary: "Other owner report"
    )
  end

  def admin_user_form_account_ids
    css_select("input[name='user[account_ids][]']").map { |input| input["value"].to_i }
  end
end
