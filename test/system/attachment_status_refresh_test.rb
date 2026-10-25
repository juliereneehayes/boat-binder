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
    configure_refresh(fast_interval: 50, slow_interval: 50)

    assert_link "Open file", count: 1, wait: 10
    assert_text "Rejected"
    assert_text "Unavailable"
    assert_text "This upload was rejected by security scanning."
    assert_text "This upload is temporarily unavailable."
    assert_no_text "Processing"
    assert_no_selector "[data-controller='attachment-status-refresh']", visible: :all
  end

  test "dirty form input remains intact beyond refresh intervals" do
    _account, owner, vessel, scan = create_vessel_refresh_scenario("dirty")
    sign_in(owner)
    visit vessel_path(vessel)

    fill_in "binder_note_title", with: "Unsaved customer note"
    configure_refresh(fast_interval: 50, slow_interval: 50)
    scan.update!(status: "clean", status_code: "NO_THREATS_FOUND", completed_at: Time.current)
    wait_for_refresh_checks

    assert_field "binder_note_title", with: "Unsaved customer note"
    assert_text "Processing"
    assert_no_link "Open file"

    visit vessel_path(vessel)
    assert_link "Open file", wait: 5
    assert_no_text "Processing"
  end

  test "focused form control pauses refresh and refresh resumes after blur when clean" do
    _account, owner, vessel, scan = create_vessel_refresh_scenario("focus")
    sign_in(owner)
    visit vessel_path(vessel)

    find_field("binder_note_title").click
    assert_equal "binder_note_title", page.evaluate_script("document.activeElement.id")
    configure_refresh(fast_interval: 50, slow_interval: 50)
    scan.update!(status: "clean", status_code: "NO_THREATS_FOUND", completed_at: Time.current)
    wait_for_refresh_checks

    assert_text "Processing"
    assert_no_link "Open file"

    page.execute_script("document.activeElement.blur()")
    assert_link "Open file", wait: 5
    assert_no_text "Processing"
  end

  test "hidden page pauses refresh until it becomes visible" do
    account = create_account(name: "Hidden Refresh Account")
    qualify_self_managed_subscription(account)
    owner = create_user(email: "attachment-refresh-hidden@example.test", role: "owner")
    create_account_membership(user: owner, account:, access_level: "editor")
    scan = create_pending_document(account:, title: "Hidden transition")
    sign_in(owner)
    visit documents_path

    set_document_hidden(true)
    configure_refresh(fast_interval: 50, slow_interval: 50)
    scan.update!(status: "clean", status_code: "NO_THREATS_FOUND", completed_at: Time.current)
    wait_for_refresh_checks

    assert_text "Processing"
    assert_no_link "Open file"

    set_document_hidden(false)
    assert_link "Open file", wait: 5
    assert_no_text "Processing"
  end

  test "browser refresh uses the gentler interval after the first minute" do
    account = create_account(name: "Backoff Refresh Account")
    qualify_self_managed_subscription(account)
    owner = create_user(email: "attachment-refresh-backoff@example.test", role: "owner")
    create_account_membership(user: owner, account:, access_level: "editor")
    scan = create_pending_document(
      account:,
      title: "Backoff transition",
      created_at: 2.minutes.ago
    )
    sign_in(owner)
    visit documents_path
    configure_refresh(fast_interval: 50, slow_interval: 400)

    scan.update!(status: "clean", status_code: "NO_THREATS_FOUND", completed_at: Time.current)
    sleep 0.2

    assert_text "Processing"
    assert_no_link "Open file"
    assert_link "Open file", wait: 5
  end

  private

  def create_pending_document(account:, title:, asset: nil, created_at: Time.current)
    document = Document.create!(account:, title:, document_type: "other")
    document.update!(asset:) if asset
    document.file.attach(
      io: file_fixture("sample.pdf").open,
      filename: "sample.pdf",
      content_type: "application/pdf"
    )
    AttachmentScan.create!(
      active_storage_blob: document.file.blob,
      status: "pending",
      provider: AttachmentScan::PROVIDER,
      created_at:
    )
  end

  def create_vessel_refresh_scenario(suffix)
    account = create_account(name: "#{suffix.titleize} Refresh Account")
    qualify_self_managed_subscription(account)
    owner = create_user(email: "attachment-refresh-#{suffix}@example.test", role: "owner")
    create_account_membership(user: owner, account:, access_level: "editor")
    vessel = create_vessel(account:, name: "#{suffix.titleize} Refresh Vessel")
    scan = create_pending_document(account:, asset: vessel, title: "#{suffix.titleize} pending document")

    [ account, owner, vessel, scan ]
  end

  def configure_refresh(fast_interval:, slow_interval:)
    page.execute_script(<<~JAVASCRIPT)
      const refresh = document.querySelector("[data-controller='attachment-status-refresh']")
      refresh.setAttribute("data-attachment-status-refresh-fast-interval-value", "#{fast_interval}")
      refresh.setAttribute("data-attachment-status-refresh-slow-interval-value", "#{slow_interval}")
    JAVASCRIPT
  end

  def wait_for_refresh_checks
    sleep 0.2
  end

  def set_document_hidden(hidden)
    page.execute_script(<<~JAVASCRIPT)
      Object.defineProperty(document, "hidden", { configurable: true, get: () => #{hidden} })
      document.dispatchEvent(new Event("visibilitychange"))
    JAVASCRIPT
  end

  def sign_in(user)
    visit new_session_path
    fill_in "Email", with: user.email_address
    fill_in "Password", with: TEST_PASSWORD
    click_button "Sign in"
    assert_current_path root_path
  end
end
