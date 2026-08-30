require "test_helper"

class BillingPortalTest < ActionDispatch::IntegrationTest
  PORTAL_SECRET = "test_controller_portal_secret"
  PORTAL_URL = "https://billing.stripe.com/p/session?secret=#{PORTAL_SECRET}"

  setup do
    @now = Time.zone.local(2026, 8, 28, 12)
    @account = create_account(name: "Portal Controller Owner")
    @owner = create_user(email: "portal-owner@example.test", role: "owner", name: "Portal Owner")
    @membership = create_account_membership(user: @owner, account: @account, access_level: "editor")
    qualify_self_managed_subscription(@account, now: @now)

    @previous_secret_key = Rails.configuration.x.stripe.secret_key
    @previous_livemode = Rails.configuration.x.stripe.livemode
    @previous_configuration_id = Rails.configuration.x.stripe.billing_portal_configuration_id
    Rails.configuration.x.stripe.secret_key = "sk_test_portal_controller"
    Rails.configuration.x.stripe.livemode = false
    Rails.configuration.x.stripe.billing_portal_configuration_id = "bpc_portal_controller"
  end

  teardown do
    Rails.configuration.x.stripe.secret_key = @previous_secret_key
    Rails.configuration.x.stripe.livemode = @previous_livemode
    Rails.configuration.x.stripe.billing_portal_configuration_id = @previous_configuration_id
  end

  test "eligible owner sees a non Turbo Manage billing form without a Stripe request on GET" do
    sign_in_as @owner

    travel_to @now do
      with_portal_api(->(*) { flunk("dashboard rendering must not call Stripe") }) do
        get root_path
      end
    end

    assert_response :success
    assert_select "form[action=?][method=post][data-turbo=false]", billing_portal_path, count: 1 do
      assert_select "button", text: "Manage billing", count: 1
    end
    assert_select "a[href=?]", billing_checkout_path, text: "View Self Managed plans", count: 0
  end

  test "Portal creation resolves Account and return URL server side and redirects with 303" do
    other_account = create_account(name: "Forged Portal Account")
    create_account_membership(user: @owner, account: other_account, access_level: "editor")
    captured_arguments = nil
    original_subscription = subscription_state
    original_counts = record_counts
    logged_redirect_payload = nil
    sign_in_as @owner

    subscriber = ActiveSupport::Notifications.subscribe("redirect_to.action_controller") do |event|
      logged_redirect_payload = event.payload
    end
    begin
      log_output = capture_rails_logs do
        travel_to @now do
          with_portal_creator(->(**arguments) {
            captured_arguments = arguments
            Struct.new(:url).new(PORTAL_URL)
          }) do
            post billing_portal_path, params: {
              account_reference: Billing::OwnerAccountReference.generate(@account),
              account_id: other_account.id,
              customer_id: "cus_attacker",
              subscription_id: "sub_attacker",
              configuration: "bpc_attacker",
              return_url: "https://attacker.example/",
              lifecycle_phase: "current_entitlement"
            }
          end
        end
      end
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    assert_response :see_other
    assert_redirected_to PORTAL_URL
    assert_equal "[FILTERED]", logged_redirect_payload.fetch(:location)
    assert_not_includes logged_redirect_payload.inspect, PORTAL_SECRET
    assert_not_includes response.body, PORTAL_SECRET
    assert_not_includes log_output, PORTAL_SECRET
    assert_equal @account, captured_arguments.fetch(:account)
    assert_equal "http://example.com/", captured_arguments.fetch(:return_url)
    assert_equal original_subscription, subscription_state
    assert_equal original_counts, record_counts
  end

  test "trialing scheduled cancellation and payment recovery Editors can start Portal sessions" do
    configurations = [
      { status: "trialing", trial_ends_at: @now + 7.days },
      {
        status: "active",
        current_period_ends_at: @now + 1.month,
        cancel_at_period_end: true
      },
      { status: "past_due" }
    ]
    sign_in_as @owner

    travel_to @now do
      configurations.each do |attributes|
        qualify_self_managed_subscription(@account, now: @now)
        @account.subscription.update!(attributes)

        with_portal_creator(->(**) { Struct.new(:url).new(PORTAL_URL) }) do
          post billing_portal_path
        end

        assert_response :see_other
        assert_redirected_to PORTAL_URL
      end
    end
  end

  test "payment recovery allows Portal but keeps owner vessel writes denied" do
    vessel = create_vessel(account: @account, name: "Recovery Vessel")
    @account.subscription.update!(status: "past_due")
    sign_in_as @owner

    travel_to @now do
      with_portal_creator(->(**) { Struct.new(:url).new(PORTAL_URL) }) do
        post billing_portal_path
      end
      assert_redirected_to PORTAL_URL

      patch vessel_path(vessel), params: { asset: { name: "Blocked recovery edit" } }
    end

    assert_access_denied_redirect
    assert_equal "Recovery Vessel", vessel.reload.name
  end

  test "read only inactive and ambiguous Account relationships cannot create Portal sessions" do
    sign_in_as @owner

    denial_configurations = [
      -> { @membership.update!(access_level: "read_only") },
      -> { @membership.update!(access_level: "editor", active: false) },
      -> { @membership.update!(active: true); @account.update!(active: false) },
      -> {
        @account.update!(active: true)
        second = create_account(name: "Second Portal Account")
        create_account_membership(user: @owner, account: second, access_level: "editor")
      }
    ]

    denial_configurations.each do |configure|
      configure.call

      assert_no_portal_creator_call do
        post billing_portal_path
      end

      assert_access_denied_redirect
    end
  end

  test "invalid signed Account references fail before Portal creation" do
    sign_in_as @owner

    assert_no_portal_creator_call do
      post billing_portal_path, params: { account_reference: "tampered-reference" }
    end

    assert_access_denied_redirect
  end

  test "unauthenticated inactive and unsupported roles cannot create Portal sessions" do
    assert_no_portal_creator_call { post billing_portal_path }
    assert_redirected_to new_session_path

    inactive_owner = create_user(email: "inactive-portal-owner@example.test", role: "owner")
    create_account_membership(user: inactive_owner, account: @account, access_level: "editor")
    sign_in_as inactive_owner
    inactive_owner.update!(active: false)

    assert_no_portal_creator_call { post billing_portal_path }
    assert_redirected_to new_session_path

    %w[admin captain].each do |role|
      user = create_user(email: "portal-#{role}@example.test", role:)
      sign_in_as user

      assert_no_portal_creator_call { post billing_portal_path }
      assert_access_denied_redirect
    end
  end

  test "wrong provider plan verification and unsupported phases fail safely" do
    sign_in_as @owner
    configurations = [
      -> { @account.subscription.update!(provider: "local") },
      -> { qualify_self_managed_subscription(@account, now: @now); @account.subscription.update!(plan: "professional") },
      -> { qualify_self_managed_subscription(@account, now: @now); @account.subscription.update!(last_synced_at: nil) },
      -> { qualify_self_managed_subscription(@account, now: @now); @account.subscription.update!(status: "suspended") },
      -> { qualify_self_managed_subscription(@account, now: @now); @account.subscription.update!(status: "canceled") }
    ]

    travel_to @now do
      configurations.each do |configure|
        configure.call

        with_portal_api(->(*) { flunk("unsupported lifecycle state must not call Stripe") }) do
          post billing_portal_path
        end

        assert_redirected_to root_path
        follow_redirect!
        assert_select "div", text: /couldn't open billing management right now/
      end
    end
  end

  test "missing configuration Stripe failures and response mismatches fail without sensitive output" do
    sign_in_as @owner

    travel_to @now do
      Rails.configuration.x.stripe.billing_portal_configuration_id = nil
      post billing_portal_path
      assert_safe_portal_failure

      Rails.configuration.x.stripe.billing_portal_configuration_id = "bpc_portal_controller"
      with_portal_api(->(*) { raise Stripe::APIConnectionError, "private Stripe network detail" }) do
        post billing_portal_path
      end
      assert_safe_portal_failure

      mismatched_session = portal_session(customer: "cus_other")
      with_portal_api(->(*) { mismatched_session }) do
        post billing_portal_path
      end
      assert_safe_portal_failure
    end
  end

  test "Portal route is POST only and retains CSRF protection" do
    get billing_portal_path
    assert_response :not_found

    sign_in_as @owner
    with_forgery_protection { post billing_portal_path }
    assert_response :unprocessable_entity
  end

  test "Portal return through the trusted dashboard makes no billing mutation" do
    original_subscription = subscription_state
    sign_in_as @owner

    travel_to @now do
      with_portal_api(->(*) { flunk("Portal return must not call Stripe") }) do
        get root_path
      end
    end

    assert_response :success
    assert_equal original_subscription, subscription_state
  end

  private

  def portal_session(customer: @account.subscription.external_customer_id)
    Stripe::BillingPortal::Session.construct_from(
      id: "bps_controller",
      customer:,
      configuration: "bpc_portal_controller",
      livemode: false,
      return_url: "http://example.com/",
      url: PORTAL_URL
    )
  end

  def with_portal_creator(replacement)
    with_singleton_method(Billing::StripePortalSessionCreator, :call, replacement) { yield }
  end

  def with_portal_api(replacement)
    with_singleton_method(Stripe::BillingPortal::Session, :create, replacement) { yield }
  end

  def assert_no_portal_creator_call(&block)
    with_portal_creator(->(**) { flunk("Portal service should not be called") }, &block)
  end

  def with_singleton_method(receiver, method_name, replacement)
    original = receiver.method(method_name)
    receiver.define_singleton_method(method_name, replacement)
    yield
  ensure
    receiver.define_singleton_method(method_name, original)
  end

  def with_forgery_protection
    previous_application_value = ApplicationController.allow_forgery_protection
    previous_base_value = ActionController::Base.allow_forgery_protection
    ApplicationController.allow_forgery_protection = true
    ActionController::Base.allow_forgery_protection = true
    yield
  ensure
    ApplicationController.allow_forgery_protection = previous_application_value
    ActionController::Base.allow_forgery_protection = previous_base_value
  end

  def subscription_state
    @account.subscription.reload.attributes.except("created_at", "updated_at")
  end

  def record_counts
    [ Account.count, Subscription.count, BillingCheckoutAttempt.count ]
  end

  def assert_safe_portal_failure
    assert_redirected_to root_path
    follow_redirect!
    assert_select "div", text: /couldn't open billing management right now/
    assert_not_includes response.body, "private Stripe network detail"
    assert_not_includes response.body, "cus_other"
  end

  def capture_rails_logs
    previous_logger = Rails.logger
    output = StringIO.new
    Rails.logger = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(output))

    yield

    output.string
  ensure
    Rails.logger = previous_logger
  end
end
