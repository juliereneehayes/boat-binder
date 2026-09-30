require "test_helper"
require "cgi"
require "stringio"

class SettingsTest < ActionDispatch::IntegrationTest
  setup do
    ActionMailer::Base.deliveries.clear
  end

  teardown do
    ActionMailer::Base.deliveries.clear
  end

  test "settings requires authentication and uses the signed-in user" do
    get settings_path
    assert_redirected_to new_session_path

    user = create_user(email: "settings-current@example.test", role: "captain", name: "Current Captain")
    other_user = create_user(email: "settings-other@example.test", role: "captain", name: "Other Captain")
    sign_in_as(user)

    get settings_path, params: { user_id: other_user.id }

    assert_response :success
    assert_includes response.body, user.email_address
    assert_not_includes response.body, other_user.email_address
    assert_select "nav a[href='#{settings_path}']", text: "Settings"
    assert_select "nav a[href='/active-sessions']", count: 0
  end

  test "name update normalizes and preserves sessions while protected attributes are ignored" do
    user = create_user(email: "settings-name@example.test", role: "owner", name: "Original Name")
    other_user = create_user(email: "settings-name-other@example.test", role: "owner", name: "Other Name")
    sign_in_as(user)
    current_session = user.sessions.sole
    other_session = Session.create_for!(user:, user_agent: "Other browser", ip_address: "192.0.2.40")
    password_digest = user.password_digest

    patch settings_path, params: {
      id: other_user.id,
      user_id: other_user.id,
      user: {
        name: "  Updated   Name  ",
        email_address: "tampered@example.test",
        role: "admin",
        active: "0",
        password: NEW_TEST_PASSWORD,
        password_confirmation: NEW_TEST_PASSWORD,
        account_memberships_attributes: { "0" => { active: "0" } }
      }
    }

    assert_redirected_to settings_path
    user.reload
    assert_equal "Updated Name", user.name
    assert_equal "settings-name@example.test", user.email_address
    assert_equal "owner", user.role
    assert user.active?
    assert_equal password_digest, user.password_digest
    assert_equal "Other Name", other_user.reload.name
    assert Session.exists?(current_session.id)
    assert Session.exists?(other_session.id)
  end

  test "invalid name renders settings errors and preserves sessions" do
    user = create_user(email: "settings-invalid-name@example.test", name: "Valid Name")
    sign_in_as(user)
    current_session = user.sessions.sole

    patch settings_path, params: { user: { name: "x" * 121 } }

    assert_response :unprocessable_entity
    assert_includes response.body, "Name is too long"
    assert_equal "Valid Name", user.reload.name
    assert Session.exists?(current_session.id)
  end

  test "email change requires the current password and leaves pending state untouched on failure" do
    user = create_user(email: "email-change-password@example.test")
    user.update!(
      pending_email_address: "previous-pending@example.test",
      email_change_requested_at: 1.hour.ago
    )
    previous_state = user.slice(:pending_email_address, :email_change_requested_at)
    sign_in_as(user)

    assert_no_difference -> { ActionMailer::Base.deliveries.size } do
      post settings_email_change_path, params: { email_change: {
        email_address: "new-pending@example.test",
        current_password: "incorrect password"
      } }
    end

    assert_response :unprocessable_entity
    assert_select "[role=alert]", text: EmailChangesController::FAILURE_MESSAGE
    assert_equal previous_state, user.reload.slice(:pending_email_address, :email_change_requested_at)
  end

  test "valid email change request normalizes pending state and mails only the new address" do
    user = create_user(email: "email-change-request@example.test", name: "Email Changer")
    sign_in_as(user)

    assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
      post settings_email_change_path, params: { email_change: {
        email_address: "  NEW-EMAIL-CHANGE@EXAMPLE.TEST  ",
        current_password: TEST_PASSWORD
      } }
    end

    assert_redirected_to settings_path
    user.reload
    assert_equal "email-change-request@example.test", user.email_address
    assert_equal "new-email-change@example.test", user.pending_email_address
    assert user.email_change_requested_at.present?
    assert_equal user, User.authenticate_by(email_address: user.email_address, password: TEST_PASSWORD)
    assert_nil User.authenticate_by(email_address: user.pending_email_address, password: TEST_PASSWORD)

    mail = ActionMailer::Base.deliveries.last
    assert_equal [ "new-email-change@example.test" ], mail.to
    assert_includes mail_body(mail), "/email-change-confirmation#token="
    assert_not_includes mail_body(mail), user.email_address
    assert_equal user, User.find_by_token_for!(:email_change, token_from(mail))
  end

  test "malformed and duplicate email change requests fail without replacing authoritative email" do
    existing = create_user(email: "email-change-existing@example.test")
    user = create_user(email: "email-change-invalid@example.test")
    sign_in_as(user)

    [ "not-an-email", "  EMAIL-CHANGE-EXISTING@EXAMPLE.TEST  " ].each do |submitted_email|
      assert_no_difference -> { ActionMailer::Base.deliveries.size } do
        post settings_email_change_path, params: { email_change: {
          email_address: submitted_email,
          current_password: TEST_PASSWORD
        } }
      end

      assert_response :unprocessable_entity
      assert_nil user.reload.pending_email_address
      assert_equal "email-change-invalid@example.test", user.email_address
    end

    assert_equal "email-change-existing@example.test", existing.reload.email_address
  end

  test "an expired pending target does not reserve the address for another user" do
    expired_holder = create_user(email: "expired-pending-holder@example.test")
    expired_holder.update!(
      pending_email_address: "reusable-pending-target@example.test",
      email_change_requested_at: 25.hours.ago
    )
    user = create_user(email: "reusable-pending-requester@example.test")
    sign_in_as(user)

    assert_not expired_holder.email_change_pending?
    request_email_change("reusable-pending-target@example.test")

    assert_equal "reusable-pending-target@example.test", user.reload.pending_email_address
    assert_equal [ "reusable-pending-target@example.test" ], ActionMailer::Base.deliveries.last.to
  end

  test "delivery failure restores the previous pending request" do
    user = create_user(email: "email-change-delivery-failure@example.test")
    user.update!(
      pending_email_address: "previous-delivery-pending@example.test",
      email_change_requested_at: 1.hour.ago
    )
    previous_state = user.slice(:pending_email_address, :email_change_requested_at)
    sign_in_as(user)
    failed_delivery = Object.new
    failed_delivery.define_singleton_method(:deliver_now) do
      raise IOError, "recipient=failed-delivery-new@example.test token=raw-mail-secret"
    end

    logs = capture_request_logs do
      with_singleton_method(EmailChangesMailer, :verify, ->(*) { failed_delivery }) do
        assert_no_difference -> { ActionMailer::Base.deliveries.size } do
          post settings_email_change_path, params: { email_change: {
            email_address: "failed-delivery-new@example.test",
            current_password: TEST_PASSWORD
          } }
        end
      end
    end

    assert_response :unprocessable_entity
    assert_select "[role=alert]", text: EmailChangesController::DELIVERY_FAILURE_MESSAGE
    assert_equal previous_state, user.reload.slice(:pending_email_address, :email_change_requested_at)
    assert_includes logs, "[FILTERED]"
    assert_includes logs, "user_id=#{user.id} exception_class=IOError"
    assert_not_includes logs, user.email_address
    assert_not_includes logs, "previous-delivery-pending@example.test"
    assert_not_includes logs, "failed-delivery-new@example.test"
    assert_not_includes logs, TEST_PASSWORD
    assert_not_includes logs, "raw-mail-secret"
  end

  test "a newer request invalidates the previous token" do
    user = create_user(email: "email-change-rotation@example.test")
    sign_in_as(user)

    request_email_change("first-rotated@example.test")
    old_token = token_from(ActionMailer::Base.deliveries.last)
    request_email_change("second-rotated@example.test")
    new_token = token_from(ActionMailer::Base.deliveries.last)

    assert_raises(ActiveSupport::MessageVerifier::InvalidSignature) do
      User.find_by_token_for!(:email_change, old_token)
    end
    assert_equal user, User.find_by_token_for!(:email_change, new_token)

    post email_change_confirmation_path, params: { token: old_token }
    assert_redirected_to new_session_path
    assert_equal EmailChangeConfirmationsController::FAILURE_MESSAGE, flash[:alert]
    assert_equal "email-change-rotation@example.test", user.reload.email_address
    assert_equal "second-rotated@example.test", user.pending_email_address
  end

  test "valid confirmation changes login email clears pending state and revokes every session" do
    user = create_user(email: "email-change-confirm@example.test")
    sign_in_as(user)
    current_session = user.sessions.sole
    other_session = Session.create_for!(user:, user_agent: "Other browser", ip_address: "192.0.2.41")
    request_email_change("confirmed-email-change@example.test")
    token = token_from(ActionMailer::Base.deliveries.last)

    post email_change_confirmation_path, params: { token: }

    assert_redirected_to new_session_path
    assert cookies[:session_id].blank?
    user.reload
    assert_equal "confirmed-email-change@example.test", user.email_address
    assert_nil user.pending_email_address
    assert_nil user.email_change_requested_at
    assert_not Session.exists?(current_session.id)
    assert_not Session.exists?(other_session.id)
    assert_nil User.authenticate_by(email_address: "email-change-confirm@example.test", password: TEST_PASSWORD)
    assert_equal user, User.authenticate_by(email_address: user.email_address, password: TEST_PASSWORD)

    post session_path, params: { email_address: "email-change-confirm@example.test", password: TEST_PASSWORD }
    assert_redirected_to new_session_path
    post session_path, params: { email_address: user.email_address, password: TEST_PASSWORD }
    assert_redirected_to root_path
  end

  test "late confirmation fails safely when the pending address became an authoritative login" do
    user = create_user(email: "late-confirmation-owner@example.test")
    user.update!(
      pending_email_address: "late-confirmation-target@example.test",
      email_change_requested_at: Time.current
    )
    token = user.generate_token_for(:email_change)
    existing_session = Session.create_for!(user:, user_agent: "Existing browser", ip_address: "192.0.2.42")
    taker = create_user(email: "late-confirmation-taker@example.test")
    taker.update!(email_address: "late-confirmation-target@example.test")

    post email_change_confirmation_path, params: { token: }

    assert_redirected_to new_session_path
    assert_equal EmailChangeConfirmationsController::FAILURE_MESSAGE, flash[:alert]
    assert_equal "late-confirmation-owner@example.test", user.reload.email_address
    assert_equal "late-confirmation-target@example.test", user.pending_email_address
    assert Session.exists?(existing_session.id)
    assert_equal "late-confirmation-target@example.test", taker.reload.email_address
  end

  test "malformed expired replayed and superseded confirmations fail closed" do
    user = create_user(email: "email-change-fail-closed@example.test")

    post email_change_confirmation_path, params: { token: "not-a-token" }
    assert_generic_confirmation_failure

    expired_token = travel_to(25.hours.ago) do
      user.update!(
        pending_email_address: "expired-email-change@example.test",
        email_change_requested_at: Time.current
      )
      user.generate_token_for(:email_change)
    end
    post email_change_confirmation_path, params: { token: expired_token }
    assert_generic_confirmation_failure
    assert_equal "email-change-fail-closed@example.test", user.reload.email_address

    user.update!(
      pending_email_address: "completed-email-change@example.test",
      email_change_requested_at: Time.current
    )
    replayed_token = user.generate_token_for(:email_change)
    post email_change_confirmation_path, params: { token: replayed_token }
    assert_redirected_to new_session_path
    post email_change_confirmation_path, params: { token: replayed_token }
    assert_generic_confirmation_failure
    assert_equal "completed-email-change@example.test", user.reload.email_address
  end

  test "confirmation landing keeps the token in the URL fragment and posts through a CSRF form" do
    previous_setting = EmailChangeConfirmationsController.allow_forgery_protection
    EmailChangeConfirmationsController.allow_forgery_protection = true

    get email_change_confirmation_path

    assert_response :success
    assert_not request.params.key?("token")
    assert_select "[data-controller=email-change-confirmation]"
    assert_select "form[action='#{email_change_confirmation_path}'][method=post][data-turbo=false]" do
      assert_select "input[name=authenticity_token]"
      assert_select "input[name=token]" do |elements|
        assert_nil elements.first["value"]
      end
    end

    source = Rails.root.join("app/javascript/controllers/email_change_confirmation_controller.js").read
    assert_operator source.index("history.replaceState"), :<, source.index("this.confirmationToken(fragment)")
    assert_operator source.index("history.replaceState"), :<, source.index("this.formTarget.requestSubmit()")
  ensure
    EmailChangeConfirmationsController.allow_forgery_protection = previous_setting
  end

  private

  def request_email_change(email_address)
    post settings_email_change_path, params: { email_change: {
      email_address:,
      current_password: TEST_PASSWORD
    } }
    assert_redirected_to settings_path
  end

  def token_from(mail)
    CGI.unescape(mail_body(mail).match(/#token=([^\s<]+)/)[1])
  end

  def mail_body(mail)
    [ mail.text_part&.body&.decoded, mail.html_part&.body&.decoded, mail.body.decoded ].compact.join("\n")
  end

  def assert_generic_confirmation_failure
    assert_redirected_to new_session_path
    assert_equal EmailChangeConfirmationsController::FAILURE_MESSAGE, flash[:alert]
  end

  def with_singleton_method(receiver, method_name, replacement)
    original_method = receiver.method(method_name)
    receiver.define_singleton_method(method_name, replacement)
    yield
  ensure
    receiver.define_singleton_method(method_name, original_method)
  end

  def capture_request_logs
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    logger.level = Logger::DEBUG
    previous_rails_logger = Rails.logger
    previous_controller_logger = ActionController::Base.logger
    Rails.logger = logger
    ActionController::Base.logger = logger

    yield
    output.string
  ensure
    ActionController::Base.logger = previous_controller_logger if previous_controller_logger
    Rails.logger = previous_rails_logger if previous_rails_logger
  end
end
