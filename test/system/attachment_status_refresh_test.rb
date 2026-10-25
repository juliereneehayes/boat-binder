require "application_system_test_case"

class AttachmentStatusRefreshTest < ApplicationSystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1200, 900 ]

  test "new vessel photo preview survives the redirect and becomes the protected clean image" do
    account = create_account(name: "Preview Vessel Account")
    user = create_user(email: "new-vessel-preview@example.test")
    sign_in(user)
    visit new_vessel_path
    track_object_urls

    attach_file "Primary vessel photo", file_fixture("sample.jpg")

    preview_url = created_object_urls.sole
    assert_selector "#vessel-primary-photo-upload-preview img[src='#{preview_url}']"
    assert_text "Saving…"

    fill_in "Vessel name", with: "Preview Passage"
    select account.name, from: "Owner account"
    click_button "Add vessel"

    assert_current_path "/vessels/preview-passage"
    vessel = Asset.find_by!(name: "Preview Passage")
    assert_current_path vessel_path(vessel)
    assert_selector "#vessel-primary-photo-upload-preview[data-turbo-permanent] img[src='#{preview_url}']"
    assert_no_selector "img[src^='#{vessel_primary_photo_path(vessel)}']"

    scan = AttachmentScan.find_by!(active_storage_blob: vessel.primary_photo.blob)
    scan.update!(status: "clean", status_code: "NO_THREATS_FOUND", completed_at: Time.current)
    configure_refresh(fast_interval: 50, slow_interval: 50)

    assert_selector "img[src='#{vessel_primary_photo_path(vessel, v: vessel.primary_photo.blob.id)}']", wait: 10
    assert_no_selector "img[src^='blob:']"
    assert_equal [ preview_url ], revoked_object_urls
  end

  test "replacement preview hides the old image and is removed after rejection" do
    account = create_account(name: "Replacement Preview Account")
    qualify_self_managed_subscription(account)
    owner = create_user(email: "replacement-preview@example.test", role: "owner")
    create_account_membership(user: owner, account:, access_level: "editor")
    vessel = create_vessel(account:, name: "Replacement Preview Vessel")
    vessel.primary_photo.attach(
      io: file_fixture("sample.jpg").open,
      filename: "old-photo.jpg",
      content_type: "image/jpeg"
    )
    trust_attachment(vessel.primary_photo)
    old_blob_id = vessel.primary_photo.blob.id
    sign_in(owner)
    visit edit_vessel_path(vessel)
    track_object_urls

    attach_file "Replace photo", file_fixture("sample.png")

    preview_url = created_object_urls.sole
    assert_selector "#vessel-primary-photo-upload-preview img[src='#{preview_url}']"
    assert_no_selector "img[src='#{vessel_primary_photo_path(vessel, v: old_blob_id)}']"
    click_button "Save vessel"

    assert_current_path vessel_path(vessel)
    assert_selector "#vessel-primary-photo-upload-preview img[src='#{preview_url}']"
    replacement_scan = AttachmentScan.find_by!(active_storage_blob: vessel.reload.primary_photo.blob)
    replacement_scan.update!(status: "rejected", status_code: "THREATS_FOUND", completed_at: Time.current)
    configure_refresh(fast_interval: 50, slow_interval: 50)

    assert_text "This upload was rejected by security scanning.", wait: 10
    assert_no_selector "img[src^='blob:']"
    assert_equal [ preview_url ], revoked_object_urls
  end

  test "service visit photo previews survive submission until protected images are clean" do
    account = create_account(name: "Visit Preview Account")
    qualify_self_managed_subscription(account)
    owner = create_user(email: "visit-preview@example.test", role: "owner")
    create_account_membership(user: owner, account:, access_level: "editor")
    vessel = create_vessel(account:, name: "Visit Preview Vessel")
    sign_in(owner)
    visit new_vessel_service_visit_path(vessel)
    track_object_urls

    attach_file "Choose or take photos", [ file_fixture("sample.jpg"), file_fixture("sample.png") ]

    preview_urls = created_object_urls
    assert_equal 2, preview_urls.size
    assert_selector "#service-visit-photos-upload-preview img[data-upload-preview-local='true']", count: 2
    assert_text "Saving…"
    click_button "Save visit report"

    assert_text "Visit report saved."
    visit_record = vessel.service_visits.reload.order(:id).last
    assert_current_path vessel_service_visit_path(vessel, visit_record)
    assert_selector "#service-visit-photos-upload-preview img[data-upload-preview-local='true']", count: 2
    scans = AttachmentScan.where(active_storage_blob_id: visit_record.photos.blobs.ids)
    assert_equal 2, scans.count
    assert_selector "[data-controller='attachment-status-refresh']", visible: :all
    protected_photo_paths = visit_record.photos.attachments.map do |attachment|
      service_visit_photo_path(vessel, visit_record, attachment)
    end
    scans.update_all(status: "clean", status_code: "NO_THREATS_FOUND", completed_at: Time.current)
    configure_refresh(fast_interval: 50, slow_interval: 50)

    protected_photo_paths.each { |path| assert_selector "img[src='#{path}']", wait: 10 }
    assert_no_selector "img[data-upload-preview-local='true']"
    assert_equal preview_urls.sort, revoked_object_urls.sort
  end

  test "normal Turbo navigation never carries one vessel photo into another vessel" do
    user = create_user(email: "vessel-photo-navigation@example.test")
    first_vessel = create_vessel(name: "First Photo Vessel")
    second_vessel = create_vessel(account: create_account(name: "Second Photo Account"), name: "Second Photo Vessel")
    first_vessel.primary_photo.attach(
      io: file_fixture("sample.jpg").open,
      filename: "first.jpg",
      content_type: "image/jpeg"
    )
    second_vessel.primary_photo.attach(
      io: file_fixture("sample.png").open,
      filename: "second.png",
      content_type: "image/png"
    )
    trust_attachment(first_vessel.primary_photo)
    trust_attachment(second_vessel.primary_photo)
    sign_in(user)
    visit vessel_path(first_vessel)

    first_path = vessel_primary_photo_path(first_vessel, v: first_vessel.primary_photo.blob.id)
    second_path = vessel_primary_photo_path(second_vessel, v: second_vessel.primary_photo.blob.id)
    assert_selector "img[src='#{first_path}']"
    page.execute_script(<<~JAVASCRIPT)
      const link = document.createElement("a")
      link.href = #{vessel_path(second_vessel).to_json}
      link.textContent = "Switch vessel"
      link.style.cssText = "position:fixed;top:0;right:0;z-index:9999;background:white;padding:12px"
      document.body.appendChild(link)
    JAVASCRIPT
    click_link "Switch vessel"

    assert_current_path vessel_path(second_vessel)
    assert_selector "img[src='#{second_path}']"
    assert_no_selector "img[src='#{first_path}']"
  end

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

    assert_text "Saving…", count: 6
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
    assert_no_text "Saving…"
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
    assert_text "Saving…"
    assert_no_link "Open file"

    visit vessel_path(vessel)
    assert_link "Open file", wait: 5
    assert_no_text "Saving…"
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

    assert_text "Saving…"
    assert_no_link "Open file"

    page.execute_script("document.activeElement.blur()")
    assert_link "Open file", wait: 5
    assert_no_text "Saving…"
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

    assert_text "Saving…"
    assert_no_link "Open file"

    set_document_hidden(false)
    assert_link "Open file", wait: 5
    assert_no_text "Saving…"
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

    assert_text "Saving…"
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

  def track_object_urls
    page.execute_script(<<~JAVASCRIPT)
      window.__uploadPreviewObjectUrls = { created: [], revoked: [] }
      const createObjectURL = URL.createObjectURL.bind(URL)
      const revokeObjectURL = URL.revokeObjectURL.bind(URL)
      URL.createObjectURL = (file) => {
        const objectUrl = createObjectURL(file)
        window.__uploadPreviewObjectUrls.created.push(objectUrl)
        return objectUrl
      }
      URL.revokeObjectURL = (objectUrl) => {
        window.__uploadPreviewObjectUrls.revoked.push(objectUrl)
        revokeObjectURL(objectUrl)
      }
    JAVASCRIPT
  end

  def created_object_urls
    page.evaluate_script("window.__uploadPreviewObjectUrls.created")
  end

  def revoked_object_urls
    page.evaluate_script("window.__uploadPreviewObjectUrls.revoked")
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
