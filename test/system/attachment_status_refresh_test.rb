require "application_system_test_case"

class AttachmentStatusRefreshTest < ApplicationSystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1200, 900 ]

  test "pending attachment states refresh through the authorized page" do
    account = create_account(name: "Refresh Account")
    qualify_self_managed_subscription(account)
    owner = create_user(email: "attachment-refresh@example.test", role: "owner")
    create_account_membership(user: owner, account:, access_level: "editor")
    clean_scan = create_pending_document(account:, title: "Clean transition")
    rejected_scan = create_pending_document(account:, title: "Rejected transition")
    failed_scan = create_pending_document(account:, title: "Failed transition")
    sign_in(owner)

    visit documents_path

    assert_text "Processing", count: 6
    assert_no_link "Open file"
    assert_selector "[data-controller='attachment-status-refresh']", count: 1, visible: :all

    clean_scan.update!(status: "clean", status_code: "NO_THREATS_FOUND", completed_at: Time.current)
    rejected_scan.update!(status: "rejected", status_code: "THREATS_FOUND", completed_at: Time.current)
    failed_scan.update!(status: "failed", status_code: "FAILED", completed_at: Time.current)
    page.execute_script(<<~JAVASCRIPT)
      document.querySelector("[data-controller='attachment-status-refresh']")
        .setAttribute("data-attachment-status-refresh-interval-value", "50")
    JAVASCRIPT

    assert_link "Open file", count: 1, wait: 10
    assert_text "Rejected"
    assert_text "Unavailable"
    assert_text "This upload was rejected by security scanning."
    assert_text "This upload is temporarily unavailable."
    assert_no_text "Processing"
    assert_no_selector "[data-controller='attachment-status-refresh']", visible: :all
  end

  private

  def create_pending_document(account:, title:)
    document = Document.create!(account:, title:, document_type: "other")
    document.file.attach(
      io: file_fixture("sample.pdf").open,
      filename: "sample.pdf",
      content_type: "application/pdf"
    )
    AttachmentScan.create!(
      active_storage_blob: document.file.blob,
      status: "pending",
      provider: AttachmentScan::PROVIDER
    )
  end

  def sign_in(user)
    visit new_session_path
    fill_in "Email", with: user.email_address
    fill_in "Password", with: TEST_PASSWORD
    click_button "Sign in"
    assert_current_path root_path
  end
end
