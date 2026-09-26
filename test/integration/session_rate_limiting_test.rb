require "test_helper"

class SessionRateLimitingTest < ActionDispatch::IntegrationTest
  def run
    @rate_limit_store = ActiveSupport::Cache::MemoryStore.new
    SessionsController.with_rate_limit_store(@rate_limit_store) { super }
  ensure
    @rate_limit_store&.clear
  end

  test "one IP is throttled when it targets many different emails" do
    rate_limit_events = capture_rate_limit_events do
      10.times do |index|
        user = create_user(email: "target-#{index}@example.test")
        post_login(email_address: user.email_address, ip_address: "192.0.2.10")
        assert_authentication_failed
      end

      post_login(email_address: "target-11@example.test", ip_address: "192.0.2.10")
      assert_throttled
    end

    assert_equal "ip", rate_limit_events.last.fetch(:name)
  end

  test "normalized email is throttled across IP addresses with a private cache key" do
    target_email = "limited-login@example.test"
    rate_limit_events = capture_rate_limit_events do
      10.times do |index|
        submitted_email = index.even? ? "  LIMITED-LOGIN@EXAMPLE.TEST  " : target_email
        post_login(email_address: submitted_email, ip_address: "198.51.100.#{index + 1}")
        assert_authentication_failed
      end

      post_login(email_address: target_email, ip_address: "198.51.100.11")
      assert_throttled
    end

    event = rate_limit_events.last
    assert_equal "email", event.fetch(:name)
    assert_match(/\A[0-9a-f]{64}\z/, event.fetch(:by))
    assert_not_equal registration_email_key(target_email), event.fetch(:by)
    assert_not_includes event.fetch(:cache_key), target_email
    assert_not_includes event.fetch(:cache_key), "LIMITED-LOGIN"
  end

  test "different emails have independent email buckets" do
    10.times do |index|
      post_login(
        email_address: "first-account@example.test",
        ip_address: "203.0.113.#{index + 1}"
      )
      assert_authentication_failed
    end

    post_login(email_address: "second-account@example.test", ip_address: "203.0.113.99")

    assert_authentication_failed
  end

  test "authenticated users redirect before either limiter and cannot switch identities" do
    current_user = create_user(email: "signed-in-rate-limit@example.test", role: "admin")
    other_user = create_user(email: "other-rate-limit@example.test")
    sign_in_as current_user
    @rate_limit_store.clear

    get new_session_path
    assert_redirected_to root_path

    assert_no_difference -> { Session.count } do
      10.times do
        post_login(
          email_address: other_user.email_address,
          password: TEST_PASSWORD,
          ip_address: "192.0.2.44"
        )
        assert_redirected_to root_path
      end
    end
    assert_equal current_user, Session.order(:created_at).last.user

    delete session_path
    10.times do
      post_login(email_address: other_user.email_address, ip_address: "192.0.2.44")
      assert_authentication_failed
    end
    post_login(email_address: other_user.email_address, ip_address: "192.0.2.44")
    assert_throttled
  end

  test "successful authentication remains compatible below both limits" do
    user = create_user(email: "successful-rate-limit@example.test")

    assert_difference -> { Session.count }, 1 do
      post_login(
        email_address: "  SUCCESSFUL-RATE-LIMIT@EXAMPLE.TEST  ",
        password: TEST_PASSWORD,
        ip_address: "198.51.100.50"
      )
    end

    assert_redirected_to root_path
    assert_equal user, Session.order(:created_at).last.user
  end

  test "inactive and unknown users retain the same generic failure" do
    inactive_user = create_user(email: "inactive-rate-limit@example.test", active: false)

    post_login(
      email_address: inactive_user.email_address,
      password: TEST_PASSWORD,
      ip_address: "198.51.100.60"
    )
    inactive_response = response_signature

    post_login(email_address: "unknown-rate-limit@example.test", ip_address: "198.51.100.61")
    unknown_response = response_signature

    assert_equal inactive_response, unknown_response
    assert_equal Authentication::GENERIC_LOGIN_FAILURE_MESSAGE, flash[:alert]
  end

  test "IP and email throttles use the same generic response" do
    10.times do |index|
      post_login(email_address: "ip-target-#{index}@example.test", ip_address: "192.0.2.70")
    end
    post_login(email_address: "ip-target-11@example.test", ip_address: "192.0.2.70")
    ip_throttle_response = response_signature

    @rate_limit_store.clear
    10.times do |index|
      post_login(
        email_address: "email-target@example.test",
        ip_address: "203.0.113.#{index + 20}"
      )
    end
    post_login(email_address: "email-target@example.test", ip_address: "203.0.113.40")
    email_throttle_response = response_signature

    assert_equal ip_throttle_response, email_throttle_response
    assert_equal SessionsController::THROTTLED_LOGIN_MESSAGE, flash[:alert]
  end

  private

  def post_login(email_address:, ip_address:, password: "incorrect password")
    post session_path,
      params: { email_address:, password: },
      headers: { "REMOTE_ADDR" => ip_address }
  end

  def assert_authentication_failed
    assert_redirected_to new_session_path
    assert_equal Authentication::GENERIC_LOGIN_FAILURE_MESSAGE, flash[:alert]
  end

  def assert_throttled
    assert_redirected_to new_session_path
    assert_equal SessionsController::THROTTLED_LOGIN_MESSAGE, flash[:alert]
  end

  def response_signature
    [ response.status, response.location, flash[:alert] ]
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

  def registration_email_key(email_address)
    EmailRateLimitKey.call(
      email_address,
      purpose: RegistrationsController::EMAIL_RATE_LIMIT_KEY_PURPOSE
    )
  end
end
