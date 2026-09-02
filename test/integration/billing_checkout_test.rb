require "test_helper"

class BillingCheckoutTest < ActionDispatch::IntegrationTest
  setup do
    @account = create_account(name: "Self Managed Checkout")
    @owner = create_user(email: "checkout-owner@example.test", role: "owner", name: "Checkout Owner")
    create_account_membership(user: @owner, account: @account, access_level: "editor")

    @previous_monthly_price_id = Rails.configuration.x.stripe.self_managed_monthly_price_id
    @previous_annual_price_id = Rails.configuration.x.stripe.self_managed_annual_price_id
    Rails.configuration.x.stripe.self_managed_monthly_price_id = "price_checkout_monthly"
    Rails.configuration.x.stripe.self_managed_annual_price_id = "price_checkout_annual"
  end

  teardown do
    Rails.configuration.x.stripe.self_managed_monthly_price_id = @previous_monthly_price_id
    Rails.configuration.x.stripe.self_managed_annual_price_id = @previous_annual_price_id
  end

  test "eligible owner can review monthly and annual Self Managed options" do
    sign_in_as @owner

    get billing_checkout_path

    assert_response :success
    assert_includes response.body, @account.name
    assert_includes response.body, "$24/month"
    assert_includes response.body, "$240/year"
    assert_equal 2, response.body.scan("7-day trial").length
    assert_select "form[action=?][method=post]", billing_checkout_path, count: 2
    assert_select "form[action=?][method=post][data-turbo=false]", billing_checkout_path, count: 2
    assert_select "input[name=option_key][value=self_managed_monthly]", count: 1
    assert_select "input[name=option_key][value=self_managed_annual]", count: 1
    assert_not_includes response.body, "price_checkout_monthly"
    assert_not_includes response.body, "price_checkout_annual"

    get root_path
    assert_includes response.body, "View Self Managed plans"
  end

  test "Checkout trial messaging follows the plan catalog" do
    definitions = Billing::SubscriptionPlanCatalog::DEFAULT_DEFINITIONS.map(&:deep_dup)
    definitions.each { |definition| definition[:trial_days] = 11 }
    catalog = Billing::SubscriptionPlanCatalog.new(
      price_ids: {
        "self_managed_monthly" => "price_checkout_monthly",
        "self_managed_annual" => "price_checkout_annual"
      },
      definitions: definitions
    )
    sign_in_as @owner

    with_singleton_method(Billing::SubscriptionPlanCatalog, :new, ->(*) { catalog }) do
      get billing_checkout_path
    end

    assert_response :success
    assert_equal 2, response.body.scan("11-day trial").length
    assert_not_includes response.body, "7-day trial"
  end

  test "Checkout trial messaging omits zero-day trials and global trial promises" do
    definitions = Billing::SubscriptionPlanCatalog::DEFAULT_DEFINITIONS.map(&:deep_dup)
    definitions.find { |definition| definition.fetch(:key) == "self_managed_monthly" }[:trial_days] = 0
    catalog = Billing::SubscriptionPlanCatalog.new(
      price_ids: {
        "self_managed_monthly" => "price_checkout_monthly",
        "self_managed_annual" => "price_checkout_annual"
      },
      definitions: definitions
    )
    sign_in_as @owner

    with_singleton_method(Billing::SubscriptionPlanCatalog, :new, ->(*) { catalog }) do
      get billing_checkout_path
    end

    assert_response :success
    assert_not_includes response.body, "0-day trial"
    assert_not_includes response.body, "Both options include a free trial."
    assert_equal 1, response.body.scan("7-day trial").length
  end

  test "disabled options are not offered for new Checkout" do
    definitions = Billing::SubscriptionPlanCatalog::DEFAULT_DEFINITIONS.map(&:deep_dup)
    definitions.find { |definition| definition.fetch(:key) == "self_managed_monthly" }[:enabled] = false
    catalog = Billing::SubscriptionPlanCatalog.new(
      price_ids: {
        "self_managed_monthly" => "price_checkout_monthly",
        "self_managed_annual" => "price_checkout_annual"
      },
      definitions: definitions
    )
    sign_in_as @owner

    with_singleton_method(Billing::SubscriptionPlanCatalog, :new, ->(*) { catalog }) do
      get billing_checkout_path
    end

    assert_response :success
    assert_select "form[action=?][method=post]", billing_checkout_path, count: 1
    assert_select "input[name=option_key][value=self_managed_monthly]", count: 0
    assert_select "input[name=option_key][value=self_managed_annual]", count: 1
  end

  test "Checkout creation resolves the account and URLs server side" do
    other_account = create_account(name: "Crafted Checkout Target")
    captured_arguments = nil
    checkout_session = Stripe::Checkout::Session.construct_from(
      id: "cs_controller",
      url: "https://checkout.stripe.com/c/pay/cs_controller"
    )
    sign_in_as @owner

    with_singleton_method(Billing::StripeCheckoutSessionCreator, :call, ->(**arguments) {
      captured_arguments = arguments
      checkout_session
    }) do
      post billing_checkout_path, params: {
        option_key: "self_managed_monthly",
        account_id: other_account.id,
        price_id: "price_attacker",
        customer_id: "cus_attacker",
        subscription_id: "sub_attacker"
      }
    end

    assert_response :see_other
    assert_redirected_to checkout_session.url
    assert_equal @account, captured_arguments.fetch(:account)
    assert_equal "self_managed_monthly", captured_arguments.fetch(:option_key)
    assert_equal "http://example.com/billing/checkout/success", captured_arguments.fetch(:success_url)
    assert_equal "http://example.com/billing/checkout/cancel", captured_arguments.fetch(:cancel_url)
    assert_not_includes captured_arguments.values, other_account.id
    assert_not_includes captured_arguments.values, "price_attacker"
    assert_not_includes captured_arguments.values, "cus_attacker"
    assert_not_includes captured_arguments.values, "sub_attacker"
  end

  test "unauthenticated and non-owner users cannot start Checkout" do
    assert_no_checkout_service_call do
      post billing_checkout_path, params: { option_key: "self_managed_monthly" }
    end
    assert_redirected_to new_session_path

    %w[admin captain].each do |role|
      delete session_path if authenticated_session?
      user = create_user(email: "checkout-#{role}@example.test", role: role)
      sign_in_as user

      assert_no_checkout_service_call do
        post billing_checkout_path, params: { option_key: "self_managed_monthly" }
      end
      assert_access_denied_redirect
    end
  end

  test "read only inactive and ambiguous owner memberships cannot start Checkout" do
    read_only_owner = create_user(email: "checkout-read-only@example.test", role: "owner")
    create_account_membership(user: read_only_owner, account: @account, access_level: "read_only")
    sign_in_as read_only_owner

    assert_no_checkout_service_call do
      post billing_checkout_path, params: { option_key: "self_managed_monthly" }
    end
    assert_access_denied_redirect
    read_only_owner.account_memberships.update_all(active: false, updated_at: Time.current)

    delete session_path
    inactive_owner = create_user(email: "checkout-inactive-membership@example.test", role: "owner")
    create_account_membership(
      user: inactive_owner,
      account: @account,
      access_level: "editor",
      active: false
    )
    sign_in_as inactive_owner

    assert_no_checkout_service_call do
      post billing_checkout_path, params: { option_key: "self_managed_monthly" }
    end
    assert_access_denied_redirect

    delete session_path
    second_account = create_account(name: "Second Eligible Checkout Account")
    create_account_membership(user: @owner, account: second_account, access_level: "editor")
    sign_in_as @owner

    assert_no_checkout_service_call do
      post billing_checkout_path, params: { option_key: "self_managed_monthly" }
    end
    assert_access_denied_redirect
  end

  test "an over-limit legacy Account cannot begin a Self Managed Checkout" do
    second_owner = create_user(email: "checkout-over-limit@example.test", role: "owner")
    create_account_membership(user: second_owner, account: @account, access_level: "read_only")
    sign_in_as @owner

    get billing_checkout_path
    assert_access_denied_redirect

    assert_no_checkout_service_call do
      post billing_checkout_path, params: { option_key: "self_managed_monthly" }
    end
    assert_access_denied_redirect
    assert_equal "legacy", @account.subscription.reload.plan
  end

  test "unknown or malformed billing options fail safely" do
    sign_in_as @owner

    post billing_checkout_path, params: { option_key: "unknown_option" }

    assert_response :unprocessable_entity
    assert_select "div", text: /We couldn't start Checkout right now/
    assert_not_includes response.body, "Unknown subscription billing option"

    post billing_checkout_path, params: { option_key: { nested: "self_managed_monthly" } }

    assert_response :unprocessable_entity
    assert_select "div", text: /We couldn't start Checkout right now/
  end

  test "missing Stripe API configuration fails safely without changing local state" do
    previous_secret_key = Rails.configuration.x.stripe.secret_key
    Rails.configuration.x.stripe.secret_key = nil
    original_attributes = subscription_state(@account.subscription)
    sign_in_as @owner

    with_singleton_method(Stripe::Customer, :create, ->(*) {
      flunk("Stripe Customer API should not be called without a secret key")
    }) do
      post billing_checkout_path, params: { option_key: "self_managed_monthly" }
    end

    assert_response :unprocessable_entity
    assert_select "div", text: /We couldn't start Checkout right now/
    assert_not_includes response.body, "Stripe API secret"
    assert_equal original_attributes, subscription_state(@account.subscription.reload)
  ensure
    Rails.configuration.x.stripe.secret_key = previous_secret_key
  end

  test "success and cancel pages are refresh safe and do not mutate subscription" do
    sign_in_as @owner
    original_attributes = subscription_state(@account.subscription)

    2.times do
      get billing_checkout_success_path
      assert_response :success
      assert_includes response.body, "subscription is being synchronized"
      assert_equal original_attributes, subscription_state(@account.subscription.reload)

      get billing_checkout_cancel_path
      assert_response :success
      assert_includes response.body, "No changes made"
      assert_equal original_attributes, subscription_state(@account.subscription.reload)
    end
  end

  test "creating Checkout and then visiting cancel leaves the local Subscription unchanged" do
    previous_secret_key = Rails.configuration.x.stripe.secret_key
    Rails.configuration.x.stripe.secret_key = "sk_test_create_then_cancel"
    original_attributes = subscription_state(@account.subscription)
    checkout_session = Stripe::Checkout::Session.construct_from(
      id: "cs_create_then_cancel",
      status: "open",
      url: "https://checkout.stripe.com/c/pay/cs_create_then_cancel"
    )
    sign_in_as @owner

    with_singleton_method(
      Stripe::Customer,
      :create,
      ->(*) { Stripe::Customer.construct_from(id: "cus_create_then_cancel") }
    ) do
      with_singleton_method(Stripe::Checkout::Session, :create, ->(*) { checkout_session }) do
        post billing_checkout_path, params: { option_key: "self_managed_monthly" }
      end
    end

    assert_redirected_to checkout_session.url
    assert_equal original_attributes, subscription_state(@account.subscription.reload)
    attempt = @account.billing_checkout_attempts.active.find_by!(
      stripe_checkout_session_id: "cs_create_then_cancel"
    )
    assert_equal "open", attempt.status

    get billing_checkout_cancel_path

    assert_response :success
    assert_includes response.body, "No changes made"
    assert_equal original_attributes, subscription_state(@account.subscription.reload)
    assert_equal "open", attempt.reload.status
  ensure
    Rails.configuration.x.stripe.secret_key = previous_secret_key
  end

  private

  def assert_no_checkout_service_call(&block)
    with_singleton_method(
      Billing::StripeCheckoutSessionCreator,
      :call,
      ->(**) { flunk("Checkout service should not be called") },
      &block
    )
  end

  def with_singleton_method(receiver, method_name, replacement)
    original_method = receiver.method(method_name)
    receiver.define_singleton_method(method_name, replacement)

    yield
  ensure
    receiver.define_singleton_method(method_name, original_method)
  end

  def authenticated_session?
    cookies[:session_id].present?
  end

  def subscription_state(subscription)
    subscription.attributes.slice(
      "plan",
      "status",
      "provider",
      "external_customer_id",
      "external_subscription_id",
      "trial_ends_at",
      "current_period_ends_at",
      "entitlement_ended_at",
      "past_due_observed_at",
      "last_synced_at"
    )
  end
end
