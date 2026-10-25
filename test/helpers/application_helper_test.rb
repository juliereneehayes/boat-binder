require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  include ApplicationHelper

  test "pending refresh tag is omitted from non-GET responses" do
    @attachment_status_refresh_required = true
    @attachment_status_refresh_started_at = Time.current
    patch_request = ActionDispatch::TestRequest.create
    patch_request.request_method = "PATCH"
    define_singleton_method(:request) { patch_request }

    assert_nil attachment_status_refresh_tag
  end
end
