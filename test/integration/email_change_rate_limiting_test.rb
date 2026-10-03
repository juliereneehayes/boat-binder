require "test_helper"

class EmailChangeRateLimitingTest < ActionDispatch::IntegrationTest
  def run
    @rate_limit_store = ActiveSupport::Cache::MemoryStore.new
    EmailChangesController.with_rate_limit_store(@rate_limit_store) { super }
  ensure
    @rate_limit_store&.clear
    ActionMailer::Base.deliveries.clear
  end

  test "first five attempts behave normally and the sixth is throttled" do
    user = create_user(email: "limited-email-change@example.test")
    sign_in_as(user)

    5.times do
      post_email_change(
        email_address: "new-limited-email-change@example.test",
        password: "incorrect password",
        ip_address: "192.0.2.50"
      )
      assert_normal_failure
    end

    assert_no_difference -> { ActionMailer::Base.deliveries.size } do
      post_email_change(
        email_address: "new-limited-email-change@example.test",
        password: TEST_PASSWORD,
        ip_address: "192.0.2.50"
      )
    end
    assert_throttled
    assert_nil user.reload.pending_email_address
  end

  test "varying source IPs share one private per-user bucket while another user is unaffected" do
    user = create_user(email: "multi-ip-email-change@example.test")
    other_user = create_user(email: "other-user-email-change@example.test")
    sign_in_as(user)

    rate_limit_events = capture_rate_limit_events do
      5.times do |index|
        post_email_change(
          email_address: "multi-ip-target@example.test",
          password: "incorrect password",
          ip_address: "198.51.100.#{index + 1}"
        )
        assert_normal_failure
      end

      post_email_change(
        email_address: "multi-ip-target@example.test",
        password: "incorrect password",
        ip_address: "198.51.100.99"
      )
      assert_throttled
    end

    event = rate_limit_events.last
    assert_equal "user", event.fetch(:name)
    assert_match(/\A[0-9a-f]{64}\z/, event.fetch(:by))
    assert_not_equal user.id.to_s, event.fetch(:by)
    assert_not_includes event.fetch(:cache_key), user.email_address
    assert_not_includes event.fetch(:cache_key), "multi-ip-target@example.test"

    sign_in_as(other_user)
    post_email_change(
      email_address: "other-user-target@example.test",
      password: "incorrect password",
      ip_address: "198.51.100.99"
    )
    assert_normal_failure
  end

  test "successful email change requests remain unchanged below the limit" do
    user = create_user(email: "successful-limited-email-change@example.test")
    sign_in_as(user)

    assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
      post_email_change(
        email_address: "successful-limited-target@example.test",
        password: TEST_PASSWORD,
        ip_address: "203.0.113.50"
      )
    end

    assert_redirected_to settings_path
    assert_equal "successful-limited-target@example.test", user.reload.pending_email_address
  end

  test "unauthenticated requests redirect before evaluating the user bucket" do
    post_email_change(
      email_address: "unauthenticated-target@example.test",
      password: "incorrect password",
      ip_address: "203.0.113.51"
    )

    assert_redirected_to new_session_path
  end

  private

  def post_email_change(email_address:, password:, ip_address:)
    post settings_email_change_path,
      params: { email_change: { email_address:, current_password: password } },
      headers: { "REMOTE_ADDR" => ip_address }
  end

  def assert_normal_failure
    assert_response :unprocessable_entity
    assert_select "[role=alert]", text: EmailChangesController::FAILURE_MESSAGE
  end

  def assert_throttled
    assert_redirected_to settings_path
    assert_equal EmailChangesController::THROTTLED_MESSAGE, flash[:alert]
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
end
