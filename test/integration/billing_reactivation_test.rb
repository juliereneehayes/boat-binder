require "test_helper"

class BillingReactivationTest < ActionDispatch::IntegrationTest
  CHECKOUT_URL = "https://checkout.stripe.com/c/pay/test_reactivation"

  setup do
    @account = create_account(name: "Reactivation Controller Account")
    @owner = create_user(email: "reactivation-owner@example.test", role: "owner")
    @membership = create_account_membership(user: @owner, account: @account, access_level: "editor")
  end

  test "active Owner Editor starts reactivation for the server-resolved Account and option" do
    captured_arguments = nil
    logged_redirect_payload = nil
    other_account = create_account(name: "Forged Reactivation Account")
    create_account_membership(user: @owner, account: other_account, access_level: "editor")
    sign_in_as @owner

    subscriber = ActiveSupport::Notifications.subscribe("redirect_to.action_controller") do |event|
      logged_redirect_payload = event.payload
    end
    begin
      with_reactivation_creator(->(**arguments) {
        captured_arguments = arguments
        Struct.new(:url).new(CHECKOUT_URL)
      }) do
        post billing_reactivation_path, params: {
          option_key: "self_managed_annual",
          account_reference: Billing::OwnerAccountReference.generate(@account),
          account_id: other_account.id,
          customer_id: "cus_attacker",
          subscription_id: "sub_attacker",
          price_id: "price_attacker",
          lifecycle_phase: "archive_eligible",
          livemode: true
        }
      end
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    assert_response :see_other
    assert_redirected_to CHECKOUT_URL
    assert_equal "[FILTERED]", logged_redirect_payload.fetch(:location)
    assert_not_includes logged_redirect_payload.inspect, "test_reactivation"
    assert_equal @account, captured_arguments.fetch(:account)
    assert_equal "self_managed_annual", captured_arguments.fetch(:option_key)
    assert_equal "http://example.com/billing/checkout/success", captured_arguments.fetch(:success_url)
    assert_equal "http://example.com/billing/checkout/cancel", captured_arguments.fetch(:cancel_url)
  end

  test "read-only inactive and ambiguous owner relationships fail before reactivation" do
    sign_in_as @owner
    denial_configurations = [
      -> { @membership.update!(access_level: "read_only") },
      -> { @membership.update!(access_level: "editor", active: false) },
      -> { @membership.update!(active: true); @account.update!(active: false) },
      -> {
        @account.update!(active: true)
        second = create_account(name: "Second Reactivation Account")
        create_account_membership(user: @owner, account: second, access_level: "editor")
      }
    ]

    denial_configurations.each do |configure|
      configure.call

      assert_no_reactivation_call do
        post billing_reactivation_path, params: { option_key: "self_managed_monthly" }
      end

      assert_access_denied_redirect
    end
  end

  test "invalid signed Account references fail before reactivation" do
    sign_in_as @owner

    assert_no_reactivation_call do
      post billing_reactivation_path, params: {
        option_key: "self_managed_monthly",
        account_reference: "tampered-reference"
      }
    end

    assert_access_denied_redirect
  end

  test "inactive users wrong roles and owners without an eligible Account are denied" do
    owner_without_account = create_user(email: "reactivation-no-account@example.test", role: "owner")
    sign_in_as owner_without_account
    assert_no_reactivation_call do
      post billing_reactivation_path, params: { option_key: "self_managed_monthly" }
    end
    assert_access_denied_redirect

    inactive_owner = create_user(email: "reactivation-inactive@example.test", role: "owner")
    create_account_membership(user: inactive_owner, account: @account, access_level: "editor")
    sign_in_as inactive_owner
    inactive_owner.update!(active: false)
    assert_no_reactivation_call do
      post billing_reactivation_path, params: { option_key: "self_managed_monthly" }
    end
    assert_redirected_to new_session_path

    %w[admin captain].each do |role|
      user = create_user(email: "reactivation-#{role}@example.test", role:)
      sign_in_as user
      assert_no_reactivation_call do
        post billing_reactivation_path, params: { option_key: "self_managed_monthly" }
      end
      assert_access_denied_redirect
    end
  end

  test "missing options and safe reactivation failures redirect without provider details" do
    sign_in_as @owner

    assert_no_reactivation_call { post billing_reactivation_path }
    assert_safe_reactivation_failure

    with_reactivation_creator(->(**) {
      raise Billing::StripeTerminalReactivationSessionCreator::ReactivationError,
        "private Stripe identifiers and payment detail"
    }) do
      post billing_reactivation_path, params: { option_key: "self_managed_monthly" }
    end
    assert_safe_reactivation_failure
    assert_not_includes response.body, "private Stripe identifiers"
  end

  test "reactivation is POST only and ordinary GETs make no reactivation request" do
    get billing_reactivation_path
    assert_response :not_found

    sign_in_as @owner
    assert_no_reactivation_call { get root_path }
    assert_response :success
  end

  test "Checkout success and cancel returns do not mutate terminal billing state" do
    now = Time.zone.local(2026, 8, 28, 12)
    @account.subscription.update!(
      provider: "stripe",
      plan: "self_managed",
      status: "canceled",
      external_customer_id: "cus_return_terminal",
      external_subscription_id: "sub_return_terminal",
      entitlement_ended_at: now - 1.day,
      last_synced_at: now - 1.day
    )
    original_state = subscription_state
    sign_in_as @owner

    get billing_checkout_success_path
    assert_response :success
    assert_equal original_state, subscription_state

    get billing_checkout_cancel_path
    assert_response :success
    assert_equal original_state, subscription_state
  end

  private

  def with_reactivation_creator(replacement)
    with_singleton_method(Billing::StripeTerminalReactivationSessionCreator, :call, replacement) { yield }
  end

  def assert_no_reactivation_call(&block)
    with_reactivation_creator(->(**) { flunk("reactivation service should not be called") }, &block)
  end

  def with_singleton_method(receiver, method_name, replacement)
    original = receiver.method(method_name)
    receiver.define_singleton_method(method_name, replacement)
    yield
  ensure
    receiver.define_singleton_method(method_name, original)
  end

  def assert_safe_reactivation_failure
    assert_response :see_other
    assert_redirected_to root_path
    follow_redirect!
    assert_select "div", text: /couldn't start reactivation right now/
  end

  def subscription_state
    @account.subscription.reload.attributes.except("created_at", "updated_at")
  end
end
