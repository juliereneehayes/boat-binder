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
    local_preview = find("#vessel-primary-photo-upload-preview img[src='#{preview_url}']")
    assert_includes local_preview[:class], "aspect-[16/10]"
    assert_text "Saving…"

    fill_in "Vessel name", with: "Preview Passage"
    select account.name, from: "Owner account"
    click_button "Add vessel"

    assert_current_path "/vessels/preview-passage"
    vessel = Asset.find_by!(name: "Preview Passage")
    assert_current_path vessel_path(vessel)
    assert_selector "#vessel-primary-photo-upload-preview[data-turbo-permanent] img[data-upload-preview-local]"
    assert_no_selector "img[src^='#{vessel_primary_photo_path(vessel)}']"
    pending_preview_url = find("#vessel-primary-photo-upload-preview img[data-upload-preview-local]")[:src]
    assert pending_preview_url.start_with?("blob:")
    assert_includes revoked_object_urls, preview_url
    refute_includes revoked_object_urls, pending_preview_url
    pending_height = page.evaluate_script("document.querySelector('#vessel-primary-photo-upload-preview img').getBoundingClientRect().height")

    scan = AttachmentScan.find_by!(active_storage_blob: vessel.primary_photo.blob)
    scan.update!(status: "clean", status_code: "NO_THREATS_FOUND", completed_at: Time.current)
    configure_refresh(fast_interval: 50, slow_interval: 50)

    server_image = find("img[src='#{vessel_primary_photo_path(vessel, v: vessel.primary_photo.blob.id)}']", wait: 10)
    assert_includes server_image[:class], "aspect-[16/10]"
    server_height = page.evaluate_script("document.querySelector('#vessel-primary-photo-upload-preview img').getBoundingClientRect().height")
    assert_in_delta pending_height, server_height, 1
    assert_no_selector "img[src^='blob:']"
    assert_equal created_object_urls.sort, revoked_object_urls.sort
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
    assert_selector "#vessel-primary-photo-upload-preview img[data-upload-preview-local]"
    active_preview_url = find("#vessel-primary-photo-upload-preview img[data-upload-preview-local]")[:src]
    assert active_preview_url.start_with?("blob:")
    refute_includes revoked_object_urls, active_preview_url
    replacement_scan = AttachmentScan.find_by!(active_storage_blob: vessel.reload.primary_photo.blob)
    replacement_scan.update!(status: "rejected", status_code: "THREATS_FOUND", completed_at: Time.current)
    configure_refresh(fast_interval: 50, slow_interval: 50)

    assert_text "This upload was rejected by security scanning.", wait: 10
    assert_no_selector "img[src^='blob:']"
    assert_equal created_object_urls.sort, revoked_object_urls.sort
  end

  test "clearing a replacement selection restores the original protected image" do
    account = create_account(name: "Cleared Replacement Account")
    qualify_self_managed_subscription(account)
    owner = create_user(email: "cleared-replacement@example.test", role: "owner")
    create_account_membership(user: owner, account:, access_level: "editor")
    vessel = create_vessel(account:, name: "Cleared Replacement Vessel")
    vessel.primary_photo.attach(
      io: file_fixture("sample.jpg").open,
      filename: "original-photo.jpg",
      content_type: "image/jpeg"
    )
    trust_attachment(vessel.primary_photo)
    original_path = vessel_primary_photo_path(vessel, v: vessel.primary_photo.blob.id)
    sign_in(owner)
    visit edit_vessel_path(vessel)
    track_object_urls

    assert_selector "#vessel-primary-photo-upload-preview img[src='#{original_path}']"
    attach_file "Replace photo", file_fixture("sample.png")

    preview_url = created_object_urls.sole
    assert_selector "#vessel-primary-photo-upload-preview img[src='#{preview_url}']"
    assert_no_selector "#vessel-primary-photo-upload-preview img[src='#{original_path}']"

    clear_file_input("Replace photo")

    assert_selector "#vessel-primary-photo-upload-preview img[src='#{original_path}']"
    assert_no_selector "#vessel-primary-photo-upload-preview img[data-upload-preview-local]"
    assert_no_selector "#vessel-primary-photo-upload-preview[data-turbo-permanent]"
    assert_no_text "Saving…"
    assert_equal [ preview_url ], revoked_object_urls
  end

  test "clearing a new vessel selection restores the default placeholder" do
    account = create_account(name: "Cleared New Vessel Account")
    user = create_user(email: "cleared-new-vessel@example.test")
    sign_in(user)
    visit new_vessel_path
    track_object_urls

    assert_selector "#vessel-primary-photo-upload-preview [role='img']"
    attach_file "Primary vessel photo", file_fixture("sample.jpg")

    preview_url = created_object_urls.sole
    assert_selector "#vessel-primary-photo-upload-preview img[src='#{preview_url}']"

    clear_file_input("Primary vessel photo")

    assert_selector "#vessel-primary-photo-upload-preview [role='img']"
    assert_no_selector "#vessel-primary-photo-upload-preview img[data-upload-preview-local]"
    assert_equal [ preview_url ], revoked_object_urls
    assert_field "Owner account", with: ""
    assert_text account.name
  end

  test "Turbo cache never restores a revoked local preview on Back navigation" do
    user = create_user(email: "preview-back-cache@example.test")
    sign_in(user)
    visit new_vessel_path
    track_object_urls
    attach_file "Primary vessel photo", file_fixture("sample.jpg")

    preview_url = created_object_urls.sole
    assert_selector "#vessel-primary-photo-upload-preview img[src='#{preview_url}']"
    click_link "Cancel"
    assert_current_path vessels_path
    assert_equal [ preview_url ], revoked_object_urls

    page.go_back

    assert_current_path new_vessel_path
    assert_selector "#vessel-primary-photo-upload-preview [role='img']"
    assert_no_selector "img[src^='blob:']"
    assert_no_selector "#vessel-primary-photo-upload-preview[data-turbo-permanent]"
  end

  test "an unsuccessful submission cannot carry its preview to an unrelated pending vessel" do
    user = create_user(email: "preview-submit-failure@example.test")
    pending_vessel = create_vessel(name: "Unrelated Pending Vessel")
    pending_vessel.primary_photo.attach(
      io: file_fixture("sample.png").open,
      filename: "pending.png",
      content_type: "image/png"
    )
    AttachmentScan.create!(
      active_storage_blob: pending_vessel.primary_photo.blob,
      status: "pending",
      provider: AttachmentScan::PROVIDER
    )
    sign_in(user)
    visit new_vessel_path
    track_object_urls
    attach_file "Primary vessel photo", file_fixture("sample.jpg")

    preview_url = created_object_urls.sole
    page.execute_script(<<~JAVASCRIPT)
      const surface = document.querySelector("#vessel-primary-photo-upload-preview")
      const form = surface.closest("[data-controller~='upload-preview']").querySelector("form")
      surface.uploadPreviewSubmitted = true
      form.dispatchEvent(new CustomEvent("turbo:submit-end", {
        bubbles: true,
        detail: { success: false }
      }))
      window.__uploadPreviewSubmittedAfterFailure = surface.uploadPreviewSubmitted
    JAVASCRIPT
    assert_equal false, page.evaluate_script("window.__uploadPreviewSubmittedAfterFailure")
    add_navigation_link(vessel_path(pending_vessel), "Open unrelated pending vessel")
    click_link "Open unrelated pending vessel"

    assert_current_path vessel_path(pending_vessel)
    assert_no_selector "img[src='#{preview_url}']"
    assert_no_selector "img[src^='blob:']"
    assert_text "Saving…"
    assert_equal [ preview_url ], revoked_object_urls
  end

  test "local preview copy becomes reassuring after the fast period" do
    user = create_user(email: "preview-finishing-copy@example.test")
    sign_in(user)
    visit new_vessel_path
    page.execute_script(<<~JAVASCRIPT)
      document.querySelector("[data-controller~='upload-preview']")
        .setAttribute("data-upload-preview-finishing-delay-value", "50")
    JAVASCRIPT

    attach_file "Primary vessel photo", file_fixture("sample.jpg")

    assert_selector "img[data-upload-preview-local][decoding='async']"
    assert_selector "[data-upload-preview-status][role='status'][aria-live='polite']", text: "Saving…"
    assert_selector "[data-upload-preview-status]", text: "Finishing upload…", wait: 5
    assert_no_text(/GuardDuty|malware|quarantine/i)
  end

  test "repeated pending refreshes preserve preview age without blank frames" do
    account = create_account(name: "Repeated Preview Refresh Account")
    user = create_user(email: "repeated-preview-refresh@example.test")
    sign_in(user)
    visit new_vessel_path
    track_object_urls
    page.execute_script(<<~JAVASCRIPT)
      document.querySelector("[data-controller~='upload-preview']")
        .setAttribute("data-upload-preview-finishing-delay-value", "500")
    JAVASCRIPT

    attach_file "Primary vessel photo", file_fixture("sample.jpg")
    page.execute_script(<<~JAVASCRIPT)
      window.__originalUploadPreviewStartedAt =
        document.querySelector("#vessel-primary-photo-upload-preview").uploadPreviewStartedAt
    JAVASCRIPT
    fill_in "Vessel name", with: "Repeated Preview Refresh"
    select account.name, from: "Owner account"
    click_button "Add vessel"

    assert_current_path "/vessels/repeated-preview-refresh"
    vessel = Asset.find_by!(name: "Repeated Preview Refresh")
    assert_current_path vessel_path(vessel)
    assert_selector "[data-controller='attachment-status-refresh']", visible: :all
    page.execute_script(<<~JAVASCRIPT)
      window.__previewBlankFrames = 0
      window.__previewFrameMonitorActive = true
      document.addEventListener("turbo:before-render", (event) => {
        const refresh = event.detail.newBody.querySelector("[data-controller='attachment-status-refresh']")
        refresh?.setAttribute("data-attachment-status-refresh-fast-interval-value", "50")
        refresh?.setAttribute("data-attachment-status-refresh-slow-interval-value", "50")
      })
      const samplePreviewFrame = () => {
        if (!window.__previewFrameMonitorActive) return
        const controller = document.querySelector("[data-upload-preview-flow-value='vessel-primary-photo']")
        const image = document.querySelector("#vessel-primary-photo-upload-preview img[data-upload-preview-local]")
        if (controller?.dataset.uploadPreviewStateValue === "pending" &&
            (!image || !image.complete || image.naturalWidth === 0)) {
          window.__previewBlankFrames += 1
        }
        requestAnimationFrame(samplePreviewFrame)
      }
      requestAnimationFrame(samplePreviewFrame)
    JAVASCRIPT
    configure_refresh(fast_interval: 50, slow_interval: 50)

    Selenium::WebDriver::Wait.new(timeout: 5).until { created_object_urls.length >= 5 }
    assert_selector "[data-upload-preview-status]", text: "Finishing upload…", wait: 5
    assert_equal page.evaluate_script("window.__originalUploadPreviewStartedAt"),
      page.evaluate_script("document.querySelector('#vessel-primary-photo-upload-preview').uploadPreviewStartedAt")
    assert_equal 0, page.evaluate_script("window.__previewBlankFrames")

    scan = AttachmentScan.find_by!(active_storage_blob: vessel.primary_photo.blob)
    scan.update!(status: "clean", status_code: "NO_THREATS_FOUND", completed_at: Time.current)
    assert_selector "img[src='#{vessel_primary_photo_path(vessel, v: vessel.primary_photo.blob.id)}']", wait: 10
    page.execute_script("window.__previewFrameMonitorActive = false")
    assert_equal created_object_urls.sort, revoked_object_urls.sort
  end

  test "a submitted replacement preview is discarded for a different vessel identity" do
    user = create_user(email: "mismatched-preview-transfer@example.test")
    source_vessel = create_vessel(name: "Preview Transfer Source")
    target_vessel = create_vessel(account: create_account(name: "Preview Transfer Target Account"), name: "Preview Transfer Target")
    target_vessel.primary_photo.attach(
      io: file_fixture("sample.png").open,
      filename: "pending.png",
      content_type: "image/png"
    )
    AttachmentScan.create!(
      active_storage_blob: target_vessel.primary_photo.blob,
      status: "pending",
      provider: AttachmentScan::PROVIDER
    )
    sign_in(user)
    visit edit_vessel_path(source_vessel)
    track_object_urls
    attach_file "Primary vessel photo", file_fixture("sample.jpg")

    preview_url = created_object_urls.sole
    page.execute_script(<<~JAVASCRIPT)
      document.querySelector("#vessel-primary-photo-upload-preview").uploadPreviewSubmitted = true
    JAVASCRIPT
    add_navigation_link(vessel_path(target_vessel), "Open different pending vessel")
    click_link "Open different pending vessel"

    assert_current_path vessel_path(target_vessel)
    assert_no_selector "img[data-upload-preview-local]"
    assert_no_selector "img[src='#{preview_url}']"
    assert_text "Saving…"
    assert_equal created_object_urls.sort, revoked_object_urls.sort
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
    assert_equal created_object_urls.sort, revoked_object_urls.sort
  end

  test "service visit preview does not duplicate a newly clean photo while its batch remains pending" do
    account = create_account(name: "Mixed Visit Preview Account")
    qualify_self_managed_subscription(account)
    owner = create_user(email: "mixed-visit-preview@example.test", role: "owner")
    create_account_membership(user: owner, account:, access_level: "editor")
    vessel = create_vessel(account:, name: "Mixed Visit Preview Vessel")
    visit_record = ServiceVisit.create!(asset: vessel, performed_by_user: owner, visit_date: Date.current)
    visit_record.photos.attach(
      io: file_fixture("sample.jpg").open,
      filename: "existing.jpg",
      content_type: "image/jpeg"
    )
    trust_attachment(visit_record.photos.first)
    existing_photo = visit_record.photos.attachments.first
    sign_in(owner)
    visit edit_vessel_service_visit_path(vessel, visit_record)
    track_object_urls

    attach_file "Choose or take photos", [ file_fixture("sample.jpg"), file_fixture("sample.png") ]
    click_button "Save visit changes"

    assert_text "Visit report updated."
    visit_record.reload
    new_photos = visit_record.photos.attachments.reject { |photo| photo.blob_id == existing_photo.blob_id }
    assert_equal 2, new_photos.size
    first_scan = AttachmentScan.find_by!(active_storage_blob_id: new_photos.first.blob_id)
    second_scan = AttachmentScan.find_by!(active_storage_blob_id: new_photos.second.blob_id)
    existing_path = service_visit_photo_path(vessel, visit_record, existing_photo)
    first_new_path = service_visit_photo_path(vessel, visit_record, new_photos.first)
    second_new_path = service_visit_photo_path(vessel, visit_record, new_photos.second)
    assert_selector "img[src='#{existing_path}']"
    assert_selector "img[data-upload-preview-local]", count: 2

    first_scan.update!(status: "clean", status_code: "NO_THREATS_FOUND", completed_at: Time.current)
    configure_refresh(fast_interval: 50, slow_interval: 50)

    assert_selector "img[data-upload-preview-local]", count: 2, wait: 10
    assert_selector "img[src='#{existing_path}']"
    assert_no_selector "img[src='#{first_new_path}']", visible: true
    assert_selector "[data-upload-preview-server-photo]", visible: true, count: 1
    current_preview_urls = page.evaluate_script("document.querySelector('#service-visit-photos-upload-preview').uploadPreviewObjectUrls")
    assert_equal 2, current_preview_urls.length
    assert_empty current_preview_urls & revoked_object_urls

    second_scan.update!(status: "clean", status_code: "NO_THREATS_FOUND", completed_at: Time.current)
    configure_refresh(fast_interval: 50, slow_interval: 50)

    assert_selector "img[src='#{first_new_path}']", wait: 10
    assert_selector "img[src='#{second_new_path}']"
    assert_no_selector "img[data-upload-preview-local]"
    assert_equal created_object_urls.sort, revoked_object_urls.sort
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

  test "pending PDF copy changes after the fast period without changing refresh semantics" do
    account = create_account(name: "Pending Copy Account")
    qualify_self_managed_subscription(account)
    owner = create_user(email: "pending-copy@example.test", role: "owner")
    create_account_membership(user: owner, account:, access_level: "editor")
    create_pending_document(account:, title: "Long PDF upload")
    sign_in(owner)
    visit documents_path

    assert_text "Saving…"
    page.execute_script(<<~JAVASCRIPT)
      const refresh = document.querySelector("[data-controller='attachment-status-refresh']")
      refresh.setAttribute("data-attachment-status-refresh-fast-window-value", "50")
    JAVASCRIPT

    assert_selector "[data-attachment-pending-copy]", text: "Finishing upload…", wait: 5
    assert_no_text(/GuardDuty|malware|quarantine/i)
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

    assert_text "Finishing upload…"
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

  def clear_file_input(label)
    input = find_field(label)
    page.execute_script(<<~JAVASCRIPT, input)
      arguments[0].value = ""
      arguments[0].dispatchEvent(new Event("change", { bubbles: true }))
    JAVASCRIPT
  end

  def add_navigation_link(path, text)
    page.execute_script(<<~JAVASCRIPT)
      const link = document.createElement("a")
      link.href = #{path.to_json}
      link.textContent = #{text.to_json}
      link.style.cssText = "position:fixed;top:0;right:0;z-index:9999;background:white;padding:12px"
      document.body.appendChild(link)
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
