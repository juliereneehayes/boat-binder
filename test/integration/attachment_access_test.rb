require "test_helper"

class AttachmentAccessTest < ActionDispatch::IntegrationTest
  setup do
    @account = create_account(name: "Attachment Account")
    qualify_self_managed_subscription(@account)
    @owner = create_user(email: "attachment-owner@example.test", role: "owner")
    @membership = create_account_membership(
      user: @owner,
      account: @account,
      access_level: "editor"
    )
    @vessel = create_vessel(account: @account, name: "Attachment Vessel")
    @document = Document.create!(
      account: @account,
      asset: @vessel,
      title: "Private policy",
      document_type: "insurance"
    )
    @document.file.attach(fixture_file_upload("sample.pdf", "application/pdf"))
    @vessel.primary_photo.attach(fixture_file_upload("sample.jpg", "image/jpeg"))
    @visit = @vessel.service_visits.create!(visit_date: Date.current, performed_by_user: @owner)
    @visit.photos.attach(fixture_file_upload("sample.png", "image/png"))
    @photo = @visit.photos.attachments.sole
    trust_attachment(@document.file)
    trust_attachment(@vessel.primary_photo)
    trust_attachment(@photo)
  end

  test "authorized same Account members stream every attachment type through private application routes" do
    sign_in_as(@owner)

    get document_file_path(@document)
    assert_response :success
    assert_equal "application/pdf", response.media_type
    assert_match(/inline/, response.headers.fetch("Content-Disposition"))
    assert_equal @document.file.blob.byte_size.to_s, response.headers.fetch("Content-Length")
    assert_private_no_store

    get document_file_path(@document, disposition: "attachment")
    assert_response :success
    assert_match(/attachment/, response.headers.fetch("Content-Disposition"))

    get vessel_primary_photo_path(@vessel)
    assert_response :success
    assert_equal "image/jpeg", response.media_type
    assert_private_no_store

    get service_visit_photo_path(@vessel, @visit, @photo)
    assert_response :success
    assert_equal "image/png", response.media_type
    assert_private_no_store
  end

  test "authorized Document range requests return only the requested bytes and partial length" do
    blob = @document.file.blob
    expected_body = blob.download.byteslice(0, 10)
    sign_in_as(@owner)

    get document_file_path(@document), headers: { "Range" => "bytes=0-9" }

    assert_response :partial_content
    assert_equal "bytes 0-9/#{blob.byte_size}", response.headers.fetch("Content-Range")
    assert_equal expected_body.bytesize.to_s, response.headers.fetch("Content-Length")
    assert_equal expected_body, response.body
    assert_equal "bytes", response.headers.fetch("Accept-Ranges")
    assert_private_no_store
  end

  test "clean attachments remain subject to authorization and stream through every protected route" do
    AttachmentScan.where(active_storage_blob_id: [
      @document.file.blob.id,
      @vessel.primary_photo.blob.id,
      @photo.blob.id
    ]).update_all(status: "clean", status_code: "NO_THREATS_FOUND", completed_at: Time.current)
    sign_in_as(@owner)

    get document_file_path(@document)
    assert_response :success
    get vessel_primary_photo_path(@vessel)
    assert_response :success
    get service_visit_photo_path(@vessel, @visit, @photo)
    assert_response :success
  end

  test "attachment pages emit only Boat Binder owned URLs" do
    sign_in_as(@owner)

    get vessel_path(@vessel)
    assert_response :success
    assert_select "img[src=?]", vessel_primary_photo_path(@vessel, v: @vessel.primary_photo.blob.id)
    assert_select "a[href^=?]", document_file_path(@document), minimum: 1
    assert_select "[src^='/rails/active_storage'], [href^='/rails/active_storage']", count: 0

    get vessel_service_visit_path(@vessel, @visit)
    assert_response :success
    assert_select "img[src=?]", service_visit_photo_path(@vessel, @visit, @photo)
    assert_select "[src^='/rails/active_storage'], [href^='/rails/active_storage']", count: 0
  end

  test "logged out requests cannot retrieve protected attachments" do
    [
      document_file_path(@document),
      vessel_primary_photo_path(@vessel),
      service_visit_photo_path(@vessel, @visit, @photo)
    ].each do |path|
      get path
      assert_redirected_to new_session_path
    end
  end

  test "users cannot retrieve another Account's attachments" do
    other_account = create_account(name: "Other Attachment Account")
    qualify_self_managed_subscription(other_account)
    other_owner = create_user(email: "other-attachment-owner@example.test", role: "owner")
    create_account_membership(user: other_owner, account: other_account, access_level: "editor")
    sign_in_as(other_owner)

    get document_file_path(@document)
    assert_response :not_found

    [
      document_path(@document),
      vessel_path(@vessel),
      vessel_service_visit_path(@vessel, @visit)
    ].each do |path|
      get path
      assert_response :not_found
      assert_select "[data-controller='attachment-status-refresh']", count: 0
    end
    get vessel_primary_photo_path(@vessel)
    assert_response :not_found
    get service_visit_photo_path(@vessel, @visit, @photo)
    assert_response :not_found
  end

  test "missing pending failed and rejected scan state all fail closed" do
    sign_in_as(@owner)

    scans = AttachmentScan.where(active_storage_blob_id: [
      @document.file.blob.id,
      @vessel.primary_photo.blob.id,
      @photo.blob.id
    ])
    scans.delete_all

    paths_and_blobs = [
      [ document_file_path(@document), @document.file.blob ],
      [ vessel_primary_photo_path(@vessel), @vessel.primary_photo.blob ],
      [ service_visit_photo_path(@vessel, @visit, @photo), @photo.blob ]
    ]

    paths_and_blobs.each do |path, blob|
      get path
      assert_response :not_found

      %w[pending failed rejected].each do |status|
        scan = AttachmentScan.create!(
          active_storage_blob: blob,
          status:,
          provider: AttachmentScan::PROVIDER,
          completed_at: status == "pending" ? nil : Time.current,
          status_code: { "failed" => "FAILED", "rejected" => "THREATS_FOUND" }[status]
        )
        get path
        assert_response :not_found
        scan.delete
      end
    end
  end

  test "authorization and parent scope are enforced before scan availability" do
    AttachmentScan.where(active_storage_blob_id: [
      @document.file.blob.id,
      @vessel.primary_photo.blob.id,
      @photo.blob.id
    ]).update_all(status: "clean", status_code: "NO_THREATS_FOUND", completed_at: Time.current)
    other_account = create_account(name: "Other Scan Scope Account")
    qualify_self_managed_subscription(other_account)
    other_owner = create_user(email: "other-scan-scope@example.test", role: "owner")
    create_account_membership(user: other_owner, account: other_account, access_level: "editor")
    sign_in_as(other_owner)

    original = AttachmentScan.method(:available_blob?)
    AttachmentScan.define_singleton_method(:available_blob?) do |_blob|
      raise "scan state must not be consulted before authorization"
    end

    get document_file_path(@document)
    assert_response :not_found
    get vessel_primary_photo_path(@vessel)
    assert_response :not_found
    get service_visit_photo_path(@vessel, @visit, @photo)
    assert_response :not_found
  ensure
    AttachmentScan.define_singleton_method(:available_blob?, original) if original
  end

  test "attachment pages suppress actions and images with exact scan-state copy" do
    sign_in_as(@owner)

    document_scan = AttachmentScan.find_by!(active_storage_blob: @document.file.blob)
    document_scan.update!(status: "pending", status_code: nil, completed_at: nil)
    get document_path(@document)
    assert_response :success
    assert_includes response.body, "Processing"
    assert_select "[data-controller='attachment-status-refresh'][data-attachment-status-refresh-interval-value='5000']", count: 1
    assert_select "a[href^=?]", document_file_path(@document), count: 0

    document_scan.update!(status: "failed", status_code: "FAILED", completed_at: Time.current)
    get document_path(@document)
    assert_includes response.body,
      "This upload is temporarily unavailable. Retry the upload. If the problem continues, contact support@boat-binder.com."
    assert_select "[data-controller='attachment-status-refresh']", count: 0
    assert_select "a[href^=?]", document_file_path(@document), count: 0

    document_scan.update!(status: "rejected", status_code: "THREATS_FOUND", completed_at: Time.current)
    get document_path(@document)
    assert_includes response.body,
      "This upload was rejected by security scanning. Retry the upload. If you believe this is an error, contact support@boat-binder.com."
    assert_select "[data-controller='attachment-status-refresh']", count: 0
    assert_select "a[href^=?]", document_file_path(@document), count: 0

    document_scan.update!(status: "clean", status_code: "NO_THREATS_FOUND", completed_at: Time.current)
    get document_path(@document)
    assert_select "[data-controller='attachment-status-refresh']", count: 0
    assert_select "a[href^=?]", document_file_path(@document), minimum: 1
    assert_not_includes response.body, "Processing"

    vessel_scan = AttachmentScan.find_by!(active_storage_blob: @vessel.primary_photo.blob)
    vessel_scan.update!(status: "pending", status_code: nil, completed_at: nil)
    get vessel_path(@vessel)
    assert_response :success
    assert_includes response.body, "Processing"
    assert_select "[data-controller='attachment-status-refresh']", count: 1
    assert_select "img[src^=?]", vessel_primary_photo_path(@vessel), count: 0

    photo_scan = AttachmentScan.find_by!(active_storage_blob: @photo.blob)
    photo_scan.update!(status: "pending", status_code: nil, completed_at: nil)
    get vessel_service_visit_path(@vessel, @visit)
    assert_response :success
    assert_includes response.body, "Processing"
    assert_select "[data-controller='attachment-status-refresh']", count: 1
    assert_select "img[src=?]", service_visit_photo_path(@vessel, @visit, @photo), count: 0
  end

  test "service visit photo identifiers must belong to the requested parent" do
    other_visit = @vessel.service_visits.create!(visit_date: Date.current, performed_by_user: @owner)
    other_visit.photos.attach(fixture_file_upload("sample.webp", "image/webp"))
    other_photo = other_visit.photos.attachments.sole
    sign_in_as(@owner)

    get service_visit_photo_path(@vessel, @visit, other_photo)
    assert_response :not_found

    other_vessel = create_vessel(account: @account, name: "Other Parent Vessel")
    get service_visit_photo_path(other_vessel, @visit, @photo)
    assert_response :not_found
  end

  test "the same application URL is reauthorized after membership revocation" do
    path = document_file_path(@document)
    sign_in_as(@owner)
    get path
    assert_response :success

    @membership.update!(active: false)
    get path
    assert_response :not_found

    @membership.update!(active: true)
    get path
    assert_response :success

    @membership.destroy!
    get path
    assert_response :not_found
  end

  test "inactive users and Accounts cannot use a previously authorized URL" do
    path = vessel_primary_photo_path(@vessel)
    sign_in_as(@owner)
    get path
    assert_response :success

    @owner.update!(active: false)
    get path
    assert_redirected_to new_session_path

    @owner.update!(active: true)
    sign_in_as(@owner)
    @account.update!(active: false)
    get path
    assert_response :not_found
  end

  test "attachment reads follow the existing subscription lifecycle policy" do
    path = service_visit_photo_path(@vessel, @visit, @photo)
    sign_in_as(@owner)

    @account.subscription.update!(status: "canceled", entitlement_ended_at: 1.day.ago)
    get path
    assert_response :success

    @account.subscription.update!(status: "suspended", entitlement_ended_at: 1.day.ago)
    get path
    assert_response :not_found
  end

  test "read only owners retain authorized attachment reads without gaining writes" do
    @membership.update!(access_level: "read_only")
    sign_in_as(@owner)

    get document_file_path(@document)
    assert_response :success

    patch document_path(@document), params: {
      document: {
        title: @document.title,
        document_type: @document.document_type,
        file: fixture_file_upload("sample.pdf", "application/pdf")
      }
    }
    assert_access_denied_redirect
  end

  test "signed blob IDs cannot be reused as uploads across Accounts or parents" do
    other_account = create_account(name: "Foreign Blob Account")
    other_document = Document.create!(
      account: other_account,
      title: "Foreign attachment",
      document_type: "other"
    )
    other_document.file.attach(fixture_file_upload("sample.png", "image/png"))
    foreign_blob = other_document.file.blob
    signed_id = foreign_blob.signed_id
    original_document_blob_id = @document.file.blob.id
    original_vessel_blob_id = @vessel.primary_photo.blob.id
    original_photo_ids = @visit.photos.blobs.ids
    sign_in_as(@owner)

    patch document_path(@document), params: {
      document: {
        account_id: @account.id,
        asset_id: @vessel.id,
        title: @document.title,
        document_type: @document.document_type,
        file: signed_id
      }
    }
    assert_response :unprocessable_entity
    assert_equal original_document_blob_id, @document.reload.file.blob.id

    patch vessel_path(@vessel), params: { asset: { name: @vessel.name, primary_photo: signed_id } }
    assert_response :unprocessable_entity
    assert_equal original_vessel_blob_id, @vessel.reload.primary_photo.blob.id

    patch vessel_service_visit_path(@vessel, @visit), params: {
      service_visit: { visit_date: @visit.visit_date, photos: [ signed_id ] }
    }
    assert_response :unprocessable_entity
    assert_equal original_photo_ids, @visit.reload.photos.blobs.ids
    assert_equal [ other_document.id ], foreign_blob.reload.attachments.pluck(:record_id)
  end

  test "unattached blobs cannot be reached through a resource attachment route" do
    unattached_blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("orphan"),
      filename: "orphan.png",
      content_type: "image/png"
    )
    sign_in_as(@owner)

    get service_visit_photo_path(@vessel, @visit, unattached_blob.id)
    assert_response :not_found
    assert_empty unattached_blob.reload.attachments
  end

  test "inactive Accounts reject new attachment writes even for internal users" do
    @account.update!(active: false)
    sign_in_as(create_user(email: "internal-attachment@example.test", role: "captain"))

    patch document_path(@document), params: {
      document: {
        account_id: @account.id,
        asset_id: @vessel.id,
        title: @document.title,
        document_type: @document.document_type,
        file: fixture_file_upload("sample.pdf", "application/pdf")
      }
    }
    assert_access_denied_redirect

    patch vessel_path(@vessel), params: {
      asset: { name: @vessel.name, primary_photo: fixture_file_upload("sample.jpg", "image/jpeg") }
    }
    assert_access_denied_redirect

    patch vessel_service_visit_path(@vessel, @visit), params: {
      service_visit: {
        visit_date: @visit.visit_date,
        photos: [ fixture_file_upload("sample.png", "image/png") ]
      }
    }
    assert_access_denied_redirect
  end

  test "default direct upload blob and representation endpoints are unavailable" do
    blob = @document.file.blob
    paths = [
      "/rails/active_storage/direct_uploads",
      "/rails/active_storage/blobs/redirect/#{blob.signed_id}/#{blob.filename}",
      "/rails/active_storage/representations/redirect/#{blob.signed_id}/invalid/#{blob.filename}"
    ]

    post paths.first
    assert_response :not_found
    paths.drop(1).each do |path|
      get path
      assert_response :not_found
    end
  end

  private

  def assert_private_no_store
    assert_includes response.headers.fetch("Cache-Control"), "private"
    assert_includes response.headers.fetch("Cache-Control"), "no-store"
    assert_equal "nosniff", response.headers.fetch("X-Content-Type-Options")
  end
end
