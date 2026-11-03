require "test_helper"

class MarketingControllerTest < ActionDispatch::IntegrationTest
  test "apex domain root is public" do
    host! "boat-binder.com"

    get "/"

    assert_response :success
    assert_select "h1", text: /Your vessel records/
    assert_select "a[href='#{signup_path}']", text: "Start Free Trial", count: 1
    assert_select "a[href='#features']", text: "Explore the product", count: 1
    assert_select "a[href='mailto:support@boat-binder.com']", minimum: 1
    assert_select "a[href='https://app.boat-binder.com/']", count: 2
    assert_not_includes response.body, "Launching soon"
    assert_not_includes response.body, "Online enrollment is not yet open"
    catalog = Billing::SubscriptionPlanCatalog.new(
      price_ids: {
        "self_managed_monthly" => "price_marketing_monthly",
        "self_managed_annual" => "price_marketing_annual"
      }
    )
    monthly = catalog.fetch("self_managed_monthly")
    annual = catalog.fetch("self_managed_annual")
    annual_savings = (monthly.amount_cents * 12) - annual.amount_cents

    assert_includes response.body, "$#{monthly.amount_cents / 100}"
    assert_includes response.body, "$#{annual.amount_cents / 100}"
    assert_includes response.body, "Save $#{annual_savings / 100}"
    assert_includes response.body, "#{monthly.trial_days}-day free trial"
  end

  test "www domain root is public" do
    host! "www.boat-binder.com"

    get "/"

    assert_response :success
    assert_select "link[rel='canonical'][href='https://boat-binder.com/']", count: 1
  end

  test "approved production homepage renders privacy-limited analytics hooks" do
    host! "boat-binder.com"

    with_singleton_method(PublicAnalytics::Configuration, :measurement_id, ->(**) { "G-TEST123" }) do
      get "/"
    end

    assert_response :success
    assert_select "body[data-controller='public-analytics'][data-public-analytics-measurement-id-value='G-TEST123']", count: 1
    assert_select "a[href='#{signup_path}'][data-action='click->public-analytics#trackSignupCta'][data-turbo='false']",
      text: "Start Free Trial", count: 1
    assert_includes response.body, "cookieless Google Analytics"
    assert_not_includes response.body, "googletagmanager.com"
  end

  test "analytics hooks are absent when configuration is disabled" do
    host! "boat-binder.com"

    get "/"

    assert_response :success
    assert_select "body[data-controller='public-analytics']", count: 0
    assert_select "a[href='#{signup_path}'][data-action]", count: 0
    assert_select "a[href='#{signup_path}'][data-turbo]", count: 0
  end

  test "staging domain root still requires authentication" do
    host! "staging.boat-binder.com"

    get "/"

    assert_redirected_to new_session_path
  end

  test "staging domain exposes the marketing preview" do
    host! "staging.boat-binder.com"

    get marketing_preview_path

    assert_response :success
    assert_select "h1"
    assert_select "a[href='#{signup_path}']", text: "Start Free Trial", count: 1
    assert_select "body[data-controller='public-analytics']", count: 0
    assert_select "a[href='#{signup_path}'][data-action]", count: 0
  end

  test "marketing preview is unavailable on production hosts" do
    [ "boat-binder.com", "www.boat-binder.com", "app.boat-binder.com" ].each do |host|
      host! host

      get "/marketing-preview"

      assert_response :not_found, "expected marketing preview to be unavailable on #{host}"
    end
  end

  test "staging signup and registration routes remain available" do
    host! "staging.boat-binder.com"

    get signup_path
    assert_response :success

    get new_registration_path
    assert_response :success
  end

  test "application domain root still requires authentication" do
    host! "app.boat-binder.com"

    get "/"

    assert_redirected_to new_session_path
  end

  private

  def with_singleton_method(receiver, method_name, replacement)
    original_method = receiver.method(method_name)
    receiver.define_singleton_method(method_name, replacement)

    yield
  ensure
    receiver.define_singleton_method(method_name, original_method)
  end
end
