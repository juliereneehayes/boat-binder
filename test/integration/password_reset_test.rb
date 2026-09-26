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
    assert_select "input[name='password'][minlength='15'][maxlength='72']"
    assert_select "input[name='password_confirmation'][minlength='15'][maxlength='72']"
    assert_includes response.body, "Use at least 15 characters. Passphrases are welcome."
  end

  test "password reset rejects a 14-character new password" do
    user = create_user(email: "short-reset@example.test")
    original_digest = user.password_digest
    token = user.password_reset_token
    short_password = "a" * 14
    user.update_column(:email_address, "not-an-email")

    put password_path(token), params: {
      password: short_password,
      password_confirmation: short_password
    }

    assert_redirected_to edit_password_path(token)
    assert_includes flash[:alert], "Password is too short (minimum is 15 characters)"
    assert_not_includes flash[:alert], "Email address"
    assert_equal original_digest, user.reload.password_digest
    assert_not user.authenticate(short_password)
  end

  test "password reset reports the bcrypt byte limit for a multibyte password" do
    user = create_user(email: "multibyte-reset@example.test")
    original_digest = user.password_digest
    token = user.password_reset_token
    oversized_password = "船" * 25

    put password_path(token), params: {
      password: oversized_password,
      password_confirmation: oversized_password
    }

    assert_redirected_to edit_password_path(token)
    assert_equal "Password is too long. Please use a shorter password.", flash[:alert]
    assert_equal original_digest, user.reload.password_digest
  end

  test "password reset reports confirmation mismatch without unrelated errors" do
    user = create_user(email: "mismatch-reset@example.test")
    token = user.password_reset_token

    put password_path(token), params: {
      password: NEW_TEST_PASSWORD,
      password_confirmation: "different-password"
    }

    assert_redirected_to edit_password_path(token)
    assert_equal "Password confirmation doesn't match Password", flash[:alert]
  end

  test "password reset reports the generic compromised-password validation" do
    user = create_user(email: "compromised-reset@example.test")
    token = user.password_reset_token
    original_checker = User.password_compromise_checker
    User.password_compromise_checker = ->(_password) { true }

    put password_path(token), params: {
      password: NEW_TEST_PASSWORD,
      password_confirmation: NEW_TEST_PASSWORD
    }

    assert_redirected_to edit_password_path(token)
    assert_equal "Password #{User::COMPROMISED_PASSWORD_MESSAGE}", flash[:alert]
  ensure
    User.password_compromise_checker = original_checker if original_checker
  end

  test "authenticated user cannot view another account password reset form" do
    signed_in_user = create_user(
      email: "signed-in-reset-form@example.test",
      role: "admin",
      name: "Signed In Admin"
    )
    reset_user = create_user(email: "reset-form-target@example.test")
    original_password_digest = reset_user.password_digest
    token = reset_user.password_reset_token
    sign_in_as signed_in_user

    assert_no_difference -> { Session.count } do
      get edit_password_path(token)
    end

    assert_redirected_to root_path
    assert_equal PasswordsController::AUTHENTICATED_RESET_MESSAGE, flash[:alert]
    follow_redirect!
    assert_response :success
    assert_includes response.body, signed_in_user.name
    assert_equal original_password_digest, reset_user.reload.password_digest
  end

  test "authenticated user cannot reset another account password" do
    signed_in_user = create_user(
      email: "signed-in-reset-update@example.test",
      role: "admin",
      name: "Signed In Admin"
    )
    reset_user = create_user(email: "reset-update-target@example.test")
    original_password_digest = reset_user.password_digest
    token = reset_user.password_reset_token
    sign_in_as signed_in_user

    assert_no_difference -> { Session.count } do
      put password_path(token), params: {
        password: NEW_TEST_PASSWORD,
        password_confirmation: NEW_TEST_PASSWORD
      }
    end

    assert_redirected_to root_path
    assert_equal PasswordsController::AUTHENTICATED_RESET_MESSAGE, flash[:alert]
    follow_redirect!
    assert_response :success
    assert_includes response.body, signed_in_user.name
    assert_equal original_password_digest, reset_user.reload.password_digest
    assert_not reset_user.authenticate(NEW_TEST_PASSWORD)

    delete session_path

    assert_no_difference -> { Session.count } do
      put password_path(token), params: {
        password: NEW_TEST_PASSWORD,
        password_confirmation: NEW_TEST_PASSWORD
      }
    end

    assert_redirected_to new_session_path
    follow_redirect!
    assert_response :success
    assert_includes response.body, "Password has been reset."
    assert reset_user.reload.authenticate(NEW_TEST_PASSWORD)
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
