require "test_helper"

class AdminSessionRevocationTest < ActionDispatch::IntegrationTest
  setup do
    @admin = create_user(email: "session-revocation-admin@example.test", role: "admin")
    @target = create_user(email: "session-revocation-target@example.test", role: "captain")
    sign_in_as(@admin)
  end

  test "successful admin password change revokes target sessions" do
    target_session = create_target_session

    patch admin_user_path(@target), params: { user: target_params(
      password: NEW_TEST_PASSWORD,
      password_confirmation: NEW_TEST_PASSWORD
    ) }

    assert_redirected_to admin_users_path
    assert_not Session.exists?(target_session.id)
  end

  test "successful admin role change revokes target sessions" do
    target_session = create_target_session

    patch admin_user_path(@target), params: { user: target_params(role: "admin") }

    assert_redirected_to admin_users_path
    assert_not Session.exists?(target_session.id)
  end

  test "successful admin active state changes revoke target sessions" do
    active_session = create_target_session
    patch admin_user_path(@target), params: { user: target_params(active: "0") }

    assert_redirected_to admin_users_path
    assert_not Session.exists?(active_session.id)

    inactive_session = create_target_session
    patch admin_user_path(@target), params: { user: target_params(active: "1") }

    assert_redirected_to admin_users_path
    assert_not Session.exists?(inactive_session.id)
  end

  test "failed admin update does not revoke target sessions" do
    target_session = create_target_session

    patch admin_user_path(@target), params: { user: target_params(
      password: NEW_TEST_PASSWORD,
      password_confirmation: "does not match"
    ) }

    assert_response :unprocessable_entity
    assert Session.exists?(target_session.id)
  end

  test "profile only admin update does not revoke target sessions" do
    target_session = create_target_session

    patch admin_user_path(@target), params: { user: target_params(name: "Updated Name") }

    assert_redirected_to admin_users_path
    assert Session.exists?(target_session.id)
  end

  test "admin changing their own role is safely required to reauthenticate" do
    current_session = @admin.sessions.sole

    patch admin_user_path(@admin), params: { user: {
      name: @admin.name,
      email_address: @admin.email_address,
      role: "captain",
      active: "1",
      password: "",
      password_confirmation: ""
    } }

    assert_redirected_to admin_users_path
    assert_not Session.exists?(current_session.id)

    get root_path
    assert_redirected_to new_session_path
    assert cookies[:session_id].blank?
  end

  private

  def create_target_session
    Session.create_for!(
      user: @target,
      user_agent: "Target browser",
      ip_address: "192.0.2.30"
    )
  end

  def target_params(overrides = {})
    {
      name: @target.name,
      email_address: @target.email_address,
      role: @target.role,
      active: @target.active? ? "1" : "0",
      password: "",
      password_confirmation: ""
    }.merge(overrides)
  end
end
