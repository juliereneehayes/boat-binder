require "test_helper"

class AdminAccountExportRequestsTest < ActionDispatch::IntegrationTest
  setup do
    @account = create_account(name: "Admin Export Account")
    @owner = create_user(email: "admin-export-owner@example.test", role: "owner", name: "Export Owner")
    @admin = create_user(email: "admin-export-reviewer@example.test", role: "admin", name: "Export Admin")
    @export_request = AccountExportRequest.create!(
      account: @account,
      requester: @owner,
      lifecycle_context: "retained_inactive"
    )
  end

  test "admin can review the minimized queue without protected Account records" do
    vessel = create_vessel(account: @account, name: "Private Queue Vessel")
    document = vessel.documents.create!(
      account: @account,
      title: "Private Queue Document",
      document_type: "other"
    )
    sign_in_as @admin

    get admin_account_export_requests_path

    assert_response :success
    assert_includes response.body, @account.name
    assert_includes response.body, @owner.name
    assert_not_includes response.body, vessel.name
    assert_not_includes response.body, document.title

    get admin_account_export_request_path(@export_request)
    assert_response :success
    assert_includes response.body, "Verify recipient"
    assert_includes response.body, "Verify scope"
    assert_not_includes response.body, vessel.name
  end

  test "approval requires recipient and scope verification and records the reviewers" do
    sign_in_as @admin

    patch admin_account_export_request_path(@export_request), params: { review_action: "approve" }
    assert_response :unprocessable_entity
    assert_includes response.body, "Recipient and data scope must be verified before approval."
    assert @export_request.reload.requested?

    patch admin_account_export_request_path(@export_request), params: { review_action: "verify_recipient" }
    assert_redirected_to admin_account_export_request_path(@export_request)
    patch admin_account_export_request_path(@export_request), params: { review_action: "verify_scope" }
    assert_redirected_to admin_account_export_request_path(@export_request)
    patch admin_account_export_request_path(@export_request), params: { review_action: "approve" }
    assert_redirected_to admin_account_export_request_path(@export_request)

    @export_request.reload
    assert @export_request.approved?
    assert_equal @admin, @export_request.recipient_verified_by
    assert_equal @admin, @export_request.scope_verified_by
    assert_equal @admin, @export_request.decided_by
  end

  test "admin can decline or fulfill while preserving audit records" do
    sign_in_as @admin

    patch admin_account_export_request_path(@export_request), params: { review_action: "decline" }
    assert_redirected_to admin_account_export_request_path(@export_request)
    assert @export_request.reload.declined?
    assert_equal @admin, @export_request.decided_by

    approved = AccountExportRequest.create!(
      account: @account,
      requester: @owner,
      lifecycle_context: "archive_eligible"
    )
    approved.verify_recipient!(reviewer: @admin)
    approved.verify_scope!(reviewer: @admin)
    approved.approve!(reviewer: @admin)

    assert_no_difference -> { AccountExportRequest.count } do
      patch admin_account_export_request_path(approved), params: { review_action: "fulfill" }
    end
    assert_redirected_to admin_account_export_request_path(approved)
    assert approved.reload.fulfilled?
    assert_equal @admin, approved.fulfilled_by
  end

  test "captain and owner cannot view or mutate the Admin queue" do
    captain = create_user(email: "export-captain@example.test", role: "captain")

    [ captain, @owner ].each do |user|
      sign_in_as user

      get admin_account_export_requests_path
      assert_access_denied_redirect

      original_status = @export_request.reload.status
      patch admin_account_export_request_path(@export_request), params: { review_action: "decline" }
      assert_access_denied_redirect
      assert_equal original_status, @export_request.reload.status
    end
  end

  test "admin navigation exposes the queue and owner navigation does not" do
    sign_in_as @admin
    get root_path
    assert_response :success
    assert_select "a[href=?]", admin_account_export_requests_path, minimum: 1

    sign_in_as @owner
    get root_path
    assert_response :success
    assert_select "a[href=?]", admin_account_export_requests_path, count: 0
  end
end
