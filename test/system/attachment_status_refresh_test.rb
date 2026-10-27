require "application_system_test_case"

class AttachmentStatusRefreshTest < ApplicationSystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1200, 900 ]

  test "new vessel photo preview survives the redirect and resolves clean on later navigation" do
    account = create_account(name: "Preview Vessel Account")
    user = create_user(email: "new-vessel-preview@example.test")
    sign_in(user)
    visit new_vessel_path
    track_object_urls
    attach_file "Primary vessel photo", file_fixture("sample.jpg")

    preview_url = created_object_urls.sole
    assert_selector "#vessel-primary-photo-upload-preview img[src='#{preview_url}']"
    assert_text "Selected photo"
    fill_in "Vessel name", with: "Preview Passage"
    select account.name, from: "Owner account"
    click_button "Add vessel"

    assert_current_path "/vessels/preview-passage"
    vessel = Asset.find_by!(name: "Preview Passage")
    assert_current_path vessel_path(vessel)
    assert_selector "#vessel-primary-photo-upload-preview img[src='#{preview_url}'][data-upload-preview-local]"
    assert_text "Processing photo…"
    assert_no_selector "img[src^='#{vessel_primary_photo_path(vessel)}']"
    assert_no_link "Check status"
    assert_equal [ preview_url ], created_object_urls
    assert_empty revoked_object_urls

    scan = AttachmentScan.find_by!(active_storage_blob: vessel.primary_photo.blob)
    scan.update!(status: "clean", status_code: "NO_THREATS_FOUND", completed_at: Time.current)
    add_navigation_link(vessel_path(vessel), "Reload vessel")
    click_link "Reload vessel"

    assert_selector "img[src='#{vessel_primary_photo_path(vessel, v: vessel.primary_photo.blob.id)}']"
    assert_no_selector "img[src^='blob:']"
    assert_equal [ preview_url ], revoked_object_urls
  end

  test "replacement preview hides the old image and resolves rejected on later navigation" do
    account = create_account(name: "Replacement Preview Account")
    qualify_self_managed_subscription(account)
    owner = create_user(email: "replacement-preview@example.test", role: "owner")
    create_account_membership(user: owner, account:, access_level: "editor")
    vessel = create_vessel(account:, name: "Replacement Preview Vessel")
    vessel.primary_photo.attach(io: file_fixture("sample.jpg").open, filename: "old-photo.jpg", content_type: "image/jpeg")
    trust_attachment(vessel.primary_photo)
    old_path = vessel_primary_photo_path(vessel, v: vessel.primary_photo.blob.id)
    sign_in(owner)
    visit edit_vessel_path(vessel)
    track_object_urls
    attach_file "Replace photo", file_fixture("sample.png")

    preview_url = created_object_urls.sole
    assert_selector "#vessel-primary-photo-upload-preview img[src='#{preview_url}']"
    assert_no_selector "img[src='#{old_path}']"
    click_button "Save vessel"

    assert_current_path vessel_path(vessel)
    assert_selector "#vessel-primary-photo-upload-preview img[src='#{preview_url}'][data-upload-preview-local]"
    assert_no_selector "img[src='#{old_path}']"
    assert_no_link "Check status"
    replacement_scan = AttachmentScan.find_by!(active_storage_blob: vessel.reload.primary_photo.blob)
    replacement_scan.update!(status: "rejected", status_code: "THREATS_FOUND", completed_at: Time.current)
    add_navigation_link(vessel_path(vessel), "Reload vessel")
    click_link "Reload vessel"

    assert_text "This upload was rejected by security scanning."
    assert_no_selector "img[src^='blob:']"
    assert_equal [ preview_url ], revoked_object_urls
  end

  test "clearing a selected replacement restores the protected image and revokes its object URL" do
    account = create_account(name: "Cleared Replacement Account")
    qualify_self_managed_subscription(account)
    owner = create_user(email: "cleared-replacement@example.test", role: "owner")
    create_account_membership(user: owner, account:, access_level: "editor")
    vessel = create_vessel(account:, name: "Cleared Replacement Vessel")
    vessel.primary_photo.attach(io: file_fixture("sample.jpg").open, filename: "original-photo.jpg", content_type: "image/jpeg")
    trust_attachment(vessel.primary_photo)
    original_path = vessel_primary_photo_path(vessel, v: vessel.primary_photo.blob.id)
    sign_in(owner)
    visit edit_vessel_path(vessel)
    track_object_urls
    attach_file "Replace photo", file_fixture("sample.png")

    preview_url = created_object_urls.sole
    assert_no_selector "#vessel-primary-photo-upload-preview img[src='#{original_path}']"
    clear_file_input("Replace photo")

    assert_selector "#vessel-primary-photo-upload-preview img[src='#{original_path}']"
    assert_no_selector "img[data-upload-preview-local]"
    assert_equal [ preview_url ], revoked_object_urls
  end

  test "failed submission cannot hand its preview to an unrelated pending vessel" do
    user = create_user(email: "preview-submit-failure@example.test")
    pending_vessel = create_vessel(name: "Unrelated Pending Vessel")
    pending_vessel.primary_photo.attach(io: file_fixture("sample.png").open, filename: "pending.png", content_type: "image/png")
    AttachmentScan.create!(active_storage_blob: pending_vessel.primary_photo.blob, status: "pending", provider: AttachmentScan::PROVIDER)
    sign_in(user)
    visit new_vessel_path
    track_object_urls
    attach_file "Primary vessel photo", file_fixture("sample.jpg")

    preview_url = created_object_urls.sole
    page.execute_script(<<~JAVASCRIPT)
      const surface = document.querySelector("#vessel-primary-photo-upload-preview")
      const form = surface.closest("[data-controller~='upload-preview']").querySelector("form")
      surface.uploadPreviewSubmitted = true
      form.dispatchEvent(new CustomEvent("turbo:submit-end", { bubbles: true, detail: { success: false } }))
    JAVASCRIPT
    add_navigation_link(vessel_path(pending_vessel), "Open unrelated pending vessel")
    click_link "Open unrelated pending vessel"

    assert_current_path vessel_path(pending_vessel)
    assert_no_selector "img[src='#{preview_url}']"
    assert_no_selector "img[src^='blob:']"
    assert_text "Processing upload…"
    assert_equal [ preview_url ], revoked_object_urls
  end

  test "a pending handoff is discarded when navigating to a different vessel" do
    account = create_account(name: "Scoped Preview Account")
    user = create_user(email: "scoped-preview@example.test")
    other_vessel = create_vessel(account:, name: "Different Preview Vessel")
    sign_in(user)
    visit new_vessel_path
    track_object_urls
    attach_file "Primary vessel photo", file_fixture("sample.jpg")

    preview_url = created_object_urls.sole
    fill_in "Vessel name", with: "Scoped Preview Vessel"
    select account.name, from: "Owner account"
    click_button "Add vessel"
    assert_current_path "/vessels/scoped-preview-vessel"
    assert_selector "img[src='#{preview_url}'][data-upload-preview-local]"

    add_navigation_link(vessel_path(other_vessel), "Open different vessel")
    click_link "Open different vessel"

    assert_current_path vessel_path(other_vessel)
    assert_no_selector "img[data-upload-preview-local]"
    assert_no_selector "img[src='#{preview_url}']"
    assert_equal [ preview_url ], revoked_object_urls
  end

  test "service visit previews remain stable until later clean navigation" do
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
    assert_selector "#service-visit-photos-upload-preview img[data-upload-preview-local]", count: 2
    click_button "Save visit report"

    assert_text "Visit report saved."
    visit_record = vessel.service_visits.reload.order(:id).last
    assert_current_path vessel_service_visit_path(vessel, visit_record)
    assert_selector "#service-visit-photos-upload-preview img[data-upload-preview-local]", count: 2
    assert_equal preview_urls.sort, current_preview_urls.sort
    assert_no_link "Check status"
    assert_empty revoked_object_urls

    AttachmentScan.where(active_storage_blob_id: visit_record.photos.blobs.ids).update_all(
      status: "clean", status_code: "NO_THREATS_FOUND", completed_at: Time.current
    )
    add_navigation_link(vessel_service_visit_path(vessel, visit_record), "Reload visit")
    click_link "Reload visit"

    visit_record.photos.attachments.each do |photo|
      assert_selector "img[src='#{service_visit_photo_path(vessel, visit_record, photo)}']"
    end
    assert_no_selector "img[data-upload-preview-local]"
    assert_equal preview_urls.sort, revoked_object_urls.sort
  end

  test "pending document shows its filename without actions and clean status is explicit" do
    account = create_account(name: "Pending Document Account")
    qualify_self_managed_subscription(account)
    owner = create_user(email: "pending-document@example.test", role: "owner")
    create_account_membership(user: owner, account:, access_level: "editor")
    document, scan = create_pending_document(account:, title: "Insurance PDF")
    sign_in(owner)
    visit document_path(document)

    assert_text "sample.pdf"
    assert_text "Processing upload…"
    assert_link "Check status"
    assert_no_link "Open file"
    assert_no_link "Download"
    assert_no_selector "img[data-upload-preview-local]"
    scan.update!(status: "clean", status_code: "NO_THREATS_FOUND", completed_at: Time.current)
    assert_no_link "Open file"
    click_link "Check status"

    assert_link "Open file"
    assert_link "Download"
  end

  test "rejected document remains unavailable after a manual status check" do
    account = create_account(name: "Rejected Document Account")
    qualify_self_managed_subscription(account)
    owner = create_user(email: "rejected-document@example.test", role: "owner")
    create_account_membership(user: owner, account:, access_level: "editor")
    document, scan = create_pending_document(account:, title: "Rejected PDF")
    sign_in(owner)
    visit document_path(document)

    scan.update!(status: "rejected", status_code: "THREATS_FOUND", completed_at: Time.current)
    click_link "Check status"

    assert_text "This upload was rejected by security scanning."
    assert_no_link "Open file"
    assert_no_link "Download"
    assert_no_link "Check status"
  end

  test "pending pages do not install an automatic refresh controller" do
    account = create_account(name: "No Polling Account")
    qualify_self_managed_subscription(account)
    owner = create_user(email: "no-polling@example.test", role: "owner")
    create_account_membership(user: owner, account:, access_level: "editor")
    document, scan = create_pending_document(account:, title: "No polling PDF")
    sign_in(owner)
    visit document_path(document)

    assert_no_selector "[data-controller='attachment-status-refresh']", visible: :all
    scan.update!(status: "clean", status_code: "NO_THREATS_FOUND", completed_at: Time.current)
    sleep 0.2

    assert_text "Processing upload…"
    assert_no_link "Open file"
  end

  private

  def create_pending_document(account:, title:)
    document = Document.create!(account:, title:, document_type: "other")
    document.file.attach(io: file_fixture("sample.pdf").open, filename: "sample.pdf", content_type: "application/pdf")
    scan = AttachmentScan.create!(active_storage_blob: document.file.blob, status: "pending", provider: AttachmentScan::PROVIDER)
    [ document, scan ]
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

  def current_preview_urls
    page.evaluate_script("document.querySelector('#service-visit-photos-upload-preview').uploadPreviewObjectUrls")
  end

  def sign_in(user)
    visit new_session_path
    fill_in "Email", with: user.email_address
    fill_in "Password", with: TEST_PASSWORD
    click_button "Sign in"
    assert_current_path root_path
  end
end
