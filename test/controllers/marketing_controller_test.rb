require "test_helper"

class MarketingControllerTest < ActionDispatch::IntegrationTest
  test "apex domain root is public" do
    host! "boat-binder.com"

    get "/"

    assert_response :success
    assert_select "h1", text: /Your vessel records/
    assert_select "a[href='mailto:support@boat-binder.com']"
    assert_includes response.body, "$24"
    assert_includes response.body, "$240"
    assert_includes response.body, "7-day free trial"
  end

  test "www domain root is public" do
    host! "www.boat-binder.com"

    get "/"

    assert_response :success
    assert_select "link[rel='canonical'][href='https://boat-binder.com/']", count: 1
  end

  test "application domain root still requires authentication" do
    host! "app.boat-binder.com"

    get "/"

    assert_redirected_to new_session_path
  end
end
