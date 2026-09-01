require "test_helper"

class MarketingControllerTest < ActionDispatch::IntegrationTest
  test "apex domain root is public" do
    host! "boat-binder.com"

    get "/"

    assert_response :success
    assert_select "h1", text: /Your vessel records/
    assert_select "a[href='mailto:support@boat-binder.com']"
    assert_select "a[href='https://app.boat-binder.com/']", count: 2
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

  test "staging domain root still requires authentication" do
    host! "staging.boat-binder.com"

    get "/"

    assert_redirected_to new_session_path
  end

  test "application domain root still requires authentication" do
    host! "app.boat-binder.com"

    get "/"

    assert_redirected_to new_session_path
  end
end
