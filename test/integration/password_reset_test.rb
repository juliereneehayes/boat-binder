require "test_helper"
require "stringio"

class PasswordResetTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  def run
    @rate_limit_store = ActiveSupport::Cache::MemoryStore.new
    PasswordsController.with_rate_limit_store(@rate_limit_store) { super }
  ensure
    @rate_limit_store&.clear
  end

  setup do
    ActionMailer::Base.deliveries.clear
    clear_enqueued_jobs
    clear_performed_jobs
  end

  teardown do
    ActionMailer::Base.deliveries.clear
    clear_enqueued_jobs
    clear_performed_jobs
  end

  test "password reset request queues only the user id and delivers asynchronously" do
    user = create_user(email: "reset@example.test")

    assert_no_difference -> { ActionMailer::Base.deliveries.size } do
      assert_enqueued_with(job: PasswordResetDeliveryJob, args: [ user.id ]) do
        post passwords_path, params: { email_address: user.email_address }
      end
    end

    assert_redirected_to new_session_path
    follow_redirect!
    assert_response :success
    assert_includes response.body, PasswordsController::RESET_REQUEST_NOTICE

    serialized_arguments = enqueued_jobs.sole.fetch(:args).to_json
    assert_not_includes serialized_arguments, user.email_address
    assert_not_includes serialized_arguments, "token"

    perform_enqueued_jobs

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

  test "existing and unknown reset requests have identical generic responses" do
    user = create_user(email: "known-generic-reset@example.test")

    assert_enqueued_with(job: PasswordResetDeliveryJob, args: [ user.id ]) do
      post passwords_path, params: { email_address: user.email_address }
    end
    known_response = reset_request_response_signature

    assert_enqueued_with(job: PasswordResetDeliveryJob, args: [ nil ]) do
      assert_no_difference -> { User.count } do
        post passwords_path, params: { email_address: "missing@example.test" }
      end
    end
    unknown_response = reset_request_response_signature

    assert_equal known_response, unknown_response
    assert_equal PasswordsController::RESET_REQUEST_NOTICE, flash[:notice]
    assert_not_includes response.body, "missing@example.test"
    assert_empty ActionMailer::Base.deliveries
  end

  test "password reset job failures do not alter the initiating response or log private details" do
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

    assert_enqueued_with(job: PasswordResetDeliveryJob, args: [ user.id ]) do
      post passwords_path, params: { email_address: user.email_address }
    end

    assert_redirected_to new_session_path
    assert_equal PasswordsController::RESET_REQUEST_NOTICE, flash[:notice]

    perform_enqueued_jobs

    assert_includes log_output.string, "Password reset email delivery failed for user_id=#{user.id}"
    assert_includes log_output.string, "exception_class=Errno::ECONNREFUSED"
    assert_not_includes log_output.string, user.email_address
    assert_not_includes log_output.string, "localhost port 25"
  ensure
    PasswordsMailer.define_singleton_method(:reset, original_reset) if original_reset
    Rails.logger = original_logger if original_logger
  end

  test "malformed or missing reset emails stay generic and enqueue privacy-preserving no-ops" do
    malformed_requests = [
      {},
      { email_address: [ "malformed-array-private@example.test" ] },
      { email_address: { private_key: "malformed-hash-private-value" } }
    ]

    malformed_requests.each do |submitted_params|
      log_output = StringIO.new
      original_logger = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(log_output)

      begin
        assert_difference -> { enqueued_jobs.size }, 1 do
          assert_enqueued_with(job: PasswordResetDeliveryJob, args: [ nil ]) do
            assert_no_difference -> { User.count } do
              assert_no_difference -> { ActionMailer::Base.deliveries.size } do
                post passwords_path, params: submitted_params
              end
            end
          end
        end

        assert_generic_reset_response
        assert_equal [ nil ], enqueued_jobs.sole.fetch(:args)

        Array.wrap(submitted_params[:email_address]).flat_map do |submitted_value|
          if submitted_value.is_a?(Hash)
            submitted_value.flat_map { |key, value| [ key.to_s, value ] }
          else
            submitted_value
          end
        end.each do |submitted_value|
          assert_not_includes response.body, submitted_value
          assert_not_includes log_output.string, submitted_value
          assert_not_includes enqueued_jobs.sole.inspect, submitted_value
        end

        assert_no_difference -> { ActionMailer::Base.deliveries.size } do
          perform_enqueued_jobs
        end
        clear_enqueued_jobs
        clear_performed_jobs
      ensure
        Rails.logger = original_logger
      end
    end
  end

  test "password reset enqueue failures preserve the generic response" do
    user = create_user(email: "queue-failure@example.test")
    original_perform_later = PasswordResetDeliveryJob.method(:perform_later)
    PasswordResetDeliveryJob.define_singleton_method(:perform_later) do |_user_id|
      raise IOError, "private queue detail"
    end
    log_output = StringIO.new
    original_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(log_output)

    post passwords_path, params: { email_address: user.email_address }

    assert_redirected_to new_session_path
    assert_equal PasswordsController::RESET_REQUEST_NOTICE, flash[:notice]
    assert_includes log_output.string, "exception_class=IOError"
    assert_not_includes log_output.string, "private queue detail"
    assert_not_includes log_output.string, user.email_address
  ensure
    PasswordResetDeliveryJob.define_singleton_method(:perform_later, original_perform_later) if original_perform_later
    Rails.logger = original_logger if original_logger
  end

  test "password reset IP throttle retains the generic response" do
    rate_limit_events = capture_rate_limit_events do
      10.times do |index|
        post_reset(email_address: "ip-reset-#{index}@example.test", ip_address: "192.0.2.10")
        assert_generic_reset_response
      end
      assert_equal 10, enqueued_jobs.size

      assert_no_enqueued_jobs do
        post_reset(email_address: "ip-reset-10@example.test", ip_address: "192.0.2.10")
        assert_generic_reset_response
      end
    end

    assert_equal 10, enqueued_jobs.size
    assert_equal "ip", rate_limit_events.last.fetch(:name)
  end

  test "normalized reset email is throttled across IPs with a private purpose-specific key" do
    target_email = "limited-reset@example.test"
    user = create_user(email: target_email)
    rate_limit_events = capture_rate_limit_events do
      5.times do |index|
        submitted_email = index.even? ? "  LIMITED-RESET@EXAMPLE.TEST  " : target_email
        post_reset(email_address: submitted_email, ip_address: "198.51.100.#{index + 1}")
        assert_generic_reset_response
      end
      assert_equal 5, enqueued_jobs.size
      assert enqueued_jobs.all? { |job| job.fetch(:args) == [ user.id ] }

      assert_no_enqueued_jobs do
        post_reset(email_address: target_email, ip_address: "198.51.100.6")
        assert_generic_reset_response
      end
    end

    assert_equal 5, enqueued_jobs.size
    event = rate_limit_events.last
    assert_equal "email", event.fetch(:name)
    assert_match(/\A[0-9a-f]{64}\z/, event.fetch(:by))
    assert_not_equal sign_in_email_key(target_email), event.fetch(:by)
    assert_not_includes event.fetch(:cache_key), target_email
    assert_not_includes event.fetch(:cache_key), "LIMITED-RESET"
  end

  test "different reset emails have independent account-targeted buckets" do
    5.times do |index|
      post_reset(email_address: "first-reset@example.test", ip_address: "203.0.113.#{index + 1}")
    end

    rate_limit_events = capture_rate_limit_events do
      post_reset(email_address: "second-reset@example.test", ip_address: "203.0.113.99")
    end

    assert_empty rate_limit_events
    assert_generic_reset_response
  end

  test "submitted reset email is filtered from request logs" do
    submitted_email = "private-reset-address@example.test"
    log_output = StringIO.new
    original_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(log_output)

    post passwords_path, params: { email_address: submitted_email }

    assert_generic_reset_response
    assert_not_includes log_output.string, submitted_email
  ensure
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

  def post_reset(email_address:, ip_address:)
    post passwords_path,
      params: { email_address: },
      headers: { "REMOTE_ADDR" => ip_address }
  end

  def assert_generic_reset_response
    assert_redirected_to new_session_path
    assert_equal PasswordsController::RESET_REQUEST_NOTICE, flash[:notice]
  end

  def reset_request_response_signature
    [ response.status, response.location, flash[:notice], flash[:alert] ]
  end

  def capture_rate_limit_events
    events = []
    subscriber = ActiveSupport::Notifications.subscribe("rate_limit.action_controller") do |*args|
      events << ActiveSupport::Notifications::Event.new(*args).payload
    end
    yield
    events
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  def sign_in_email_key(email_address)
    EmailRateLimitKey.call(
      email_address,
      purpose: SessionsController::EMAIL_RATE_LIMIT_KEY_PURPOSE
    )
  end

  def mail_body(mail)
    if mail.multipart?
      mail.parts.map { |part| part.body.encoded }.join("\n")
    else
      mail.body.encoded
    end
  end
end
