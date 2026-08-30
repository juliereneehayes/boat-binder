require "test_helper"

class AccountExportRequestTest < ActiveSupport::TestCase
  setup do
    @account = create_account(name: "Export Audit Account")
    @owner = create_user(email: "export-requester@example.test", role: "owner")
    @admin = create_user(email: "export-reviewer@example.test", role: "admin")
  end

  test "only one open request is allowed per Account while closed history remains" do
    request = create_request

    duplicate = AccountExportRequest.new(
      account: @account,
      requester: @owner,
      lifecycle_context: "read_only_grace"
    )
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:account_id], "already has an open export request"

    request.decline!(reviewer: @admin)
    replacement = create_request

    assert replacement.requested?
    assert_equal 2, AccountExportRequest.where(account: @account).count
  end

  test "database protects against duplicate open requests" do
    create_request

    assert_raises(ActiveRecord::RecordNotUnique) do
      AccountExportRequest.insert_all!([ {
        account_id: @account.id,
        requester_id: @owner.id,
        lifecycle_context: "retained_inactive",
        status: "requested",
        created_at: Time.current,
        updated_at: Time.current
      } ])
    end
  end

  test "approval requires independently recorded recipient and scope verification" do
    request = create_request

    error = assert_raises(ActiveRecord::RecordInvalid) do
      request.approve!(reviewer: @admin)
    end
    assert_includes error.record.errors.full_messages,
      "Recipient and data scope must be verified before approval."

    request.verify_recipient!(reviewer: @admin)
    request.verify_scope!(reviewer: @admin)
    request.approve!(reviewer: @admin)

    assert request.approved?
    assert_equal @admin, request.recipient_verified_by
    assert_equal @admin, request.scope_verified_by
    assert_equal @admin, request.decided_by
    assert request.decided_at?
  end

  test "fulfillment preserves the request and its audit trail" do
    request = create_request
    request.verify_recipient!(reviewer: @admin)
    request.verify_scope!(reviewer: @admin)
    request.approve!(reviewer: @admin)
    decided_at = request.decided_at

    request.fulfill!(reviewer: @admin)

    assert request.fulfilled?
    assert_equal decided_at, request.decided_at
    assert_equal @admin, request.fulfilled_by
    assert request.fulfilled_at?
    assert AccountExportRequest.exists?(request.id)
  end

  private

  def create_request
    AccountExportRequest.create!(
      account: @account,
      requester: @owner,
      lifecycle_context: "read_only_grace"
    )
  end
end
