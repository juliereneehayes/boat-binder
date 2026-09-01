require "test_helper"
require "stringio"

class PasswordResetTest < ActionDispatch::IntegrationTest
  setup do
    ActionMailer::Base.deliveries.clear
  end

  teardown do
    ActionMailer::Base.deliveries.clear
  end

  test "password reset request sends instructions synchronously with generic messaging" do
    user = create_user(email: "reset@example.test")

    assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
      post passwords_path, params: { email_address: user.email_address }
    end

    assert_redirected_to new_session_path
    follow_redirect!
    assert_response :success
    assert_includes response.body, PasswordsController::RESET_REQUEST_NOTICE

    mail = ActionMailer::Base.deliveries.last
    assert_equal [ user.email_address ], mail.to
    assert_equal "Reset your password", mail.subject
    assert_includes mail_body(mail), "http://example.com/passwords/"
  end

  test "password reset token lookup finds the reset user" do
    user = create_user(email: "token-lookup@example.test")
    token = user.password_reset_token

    assert_equal User::PASSWORD_RESET_EXPIRES_IN, user.password_reset_token_expires_in
    assert_equal user, User.find_by_password_reset_token!(token)

    get edit_password_path(token)

    assert_response :success
  end

  test "authenticated password reset preserves the current session identity" do
    signed_in_user = create_user(
      email: "signed-in-reset@example.test",
      role: "admin",
      name: "Signed In Admin"
    )
    reset_user = create_user(email: "reset-target@example.test")
    token = reset_user.password_reset_token
    sign_in_as signed_in_user

    assert_no_difference -> { Session.count } do
      put password_path(token), params: {
        password: "new-password",
        password_confirmation: "new-password"
      }
    end

    assert_redirected_to new_session_path
    follow_redirect!
    assert_redirected_to root_path
    follow_redirect!
    assert_response :success
    assert_includes response.body, signed_in_user.name
    assert reset_user.reload.authenticate("new-password")
  end

  test "password reset request keeps generic messaging when email is unknown" do
    assert_no_difference -> { ActionMailer::Base.deliveries.size } do
      post passwords_path, params: { email_address: "missing@example.test" }
    end

    assert_redirected_to new_session_path
    follow_redirect!
    assert_response :success
    assert_includes response.body, PasswordsController::RESET_REQUEST_NOTICE
    assert_not_includes response.body, "missing@example.test"
  end

  test "password reset delivery failures are logged and do not return server errors" do
    user = create_user(email: "smtp-failure@example.test")
    log_output = StringIO.new
    original_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(log_output)
    failed_delivery = Object.new
    failed_delivery.define_singleton_method(:deliver_now) do
      raise Errno::ECONNREFUSED, "connect(2) for localhost port 25"
    end
    original_reset = PasswordsMailer.method(:reset)
    PasswordsMailer.define_singleton_method(:reset) { |_user| failed_delivery }

    assert_no_difference -> { ActionMailer::Base.deliveries.size } do
      post passwords_path, params: { email_address: user.email_address }
    end

    assert_redirected_to new_session_path
    follow_redirect!
    assert_response :success
    assert_includes response.body, PasswordsController::RESET_REQUEST_NOTICE
    assert_not_includes response.body, user.email_address
    assert_includes log_output.string, "Password reset email delivery failed for user_id=#{user.id}"
    assert_includes log_output.string, "Errno::ECONNREFUSED"
  ensure
    PasswordsMailer.define_singleton_method(:reset, original_reset) if original_reset
    Rails.logger = original_logger if original_logger
  end

  test "password reset email uses the configured app host for reset links" do
    original_options = PasswordsMailer.default_url_options
    PasswordsMailer.default_url_options = original_options.merge(host: "app.boat-binder.com", protocol: "https")
    user = create_user(email: "host-check@example.test")

    mail = PasswordsMailer.reset(user)

    assert_includes mail_body(mail), "https://app.boat-binder.com/passwords/"
  ensure
    PasswordsMailer.default_url_options = original_options
  end

  test "password reset email uses configured default sender" do
    original_options = Rails.application.config.action_mailer.default_options
    Rails.application.config.action_mailer.default_options = (original_options || {}).merge(from: "Boat Binder <no-reply@example.test>")
    user = create_user(email: "sender-check@example.test")

    mail = PasswordsMailer.reset(user)

    assert_equal [ "no-reply@example.test" ], mail.from
    assert_equal [ "Boat Binder" ], mail[:from].addrs.map(&:display_name)
  ensure
    Rails.application.config.action_mailer.default_options = original_options
  end

  private

  def mail_body(mail)
    if mail.multipart?
      mail.parts.map { |part| part.body.encoded }.join("\n")
    else
      mail.body.encoded
    end
  end
end
