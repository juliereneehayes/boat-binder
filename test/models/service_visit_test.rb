require "test_helper"

class ServiceVisitTest < ActiveSupport::TestCase
  test "belongs to an asset and captain" do
    asset = create_vessel
    user = create_user
    visit = ServiceVisit.create!(asset: asset, performed_by_user: user, visit_date: Date.current, engine_hours: 10.5)

    assert_equal asset, visit.asset
    assert_equal user, visit.performed_by_user
  end

  test "does not allow negative engine hours" do
    visit = ServiceVisit.new(asset: create_vessel, performed_by_user: create_user, visit_date: Date.current, engine_hours: -1)

    assert_not visit.valid?
    assert_includes visit.errors[:engine_hours], "must be greater than or equal to 0"
  end

  test "builds default inspection checks and engine readings" do
    vessel = create_vessel
    visit = ServiceVisit.new(asset: vessel, performed_by_user: create_user, visit_date: Date.current)

    visit.build_workflow_defaults

    assert_equal [ "Port Engine", "Starboard Engine" ], visit.ordered_engine_readings.map(&:display_name)
    assert_equal ServiceVisit::DEFAULT_INSPECTION_LABELS, visit.ordered_inspection_checks.map(&:label)
  end

  test "builds battery checks for active batteries only" do
    vessel = create_vessel
    active_battery = create_battery(asset: vessel, name: "House Battery 1")
    AssetBattery.create!(asset: vessel, name: "Old Battery", active: false)
    visit = ServiceVisit.new(asset: vessel, performed_by_user: create_user, visit_date: Date.current)

    visit.build_workflow_defaults

    assert_equal [ active_battery ], visit.service_visit_battery_checks.map(&:asset_battery)
  end

  test "summary recipient email uses the account transactional recipient source" do
    account = create_account(name: "Service Summary Owner")
    account.contacts.create!(name: "Fallback Owner", email: "fallback-summary@example.test", role: "Owner")
    owner = create_user(email: "linked-summary-owner@example.test", role: "owner")
    create_account_membership(user: owner, account: account)
    visit = ServiceVisit.create!(
      asset: create_vessel(account: account),
      performed_by_user: create_user(email: "captain-summary-recipient@example.test"),
      visit_date: Date.current
    )

    assert_equal account.transactional_recipient_email, visit.summary_recipient_email
    assert_equal "linked-summary-owner@example.test", visit.summary_recipient_email
  end

  test "completes and reopens follow up with an auditable history" do
    actor = create_user(email: "follow-up-actor@example.test", name: "Follow Up Actor")
    visit = ServiceVisit.create!(
      asset: create_vessel,
      performed_by_user: create_user(email: "visit-author@example.test"),
      visit_date: Date.current,
      follow_up_needed: true,
      follow_up_notes: "Order a replacement impeller."
    )

    travel_to Time.zone.local(2026, 9, 4, 9, 30) do
      assert visit.complete_follow_up!(by: actor)
    end

    visit.reload
    assert visit.follow_up_completed?
    assert_equal actor, visit.follow_up_completed_by_user
    assert_equal Time.zone.local(2026, 9, 4, 9, 30), visit.follow_up_completed_at
    assert_equal "Order a replacement impeller.", visit.follow_up_notes
    assert_equal [ "completed" ], visit.follow_up_events.pluck(:action)

    travel_to Time.zone.local(2026, 9, 4, 10, 15) do
      assert visit.reopen_follow_up!(by: actor)
    end

    visit.reload
    assert visit.follow_up_open?
    assert_nil visit.follow_up_completed_at
    assert_nil visit.follow_up_completed_by_user
    assert_equal "Order a replacement impeller.", visit.follow_up_notes
    assert_equal [ "completed", "reopened" ], visit.follow_up_events.pluck(:action)
  end

  test "follow up transitions are idempotent" do
    actor = create_user(email: "idempotent-follow-up@example.test")
    visit = ServiceVisit.create!(
      asset: create_vessel,
      performed_by_user: actor,
      visit_date: Date.current,
      follow_up_needed: true
    )

    assert visit.complete_follow_up!(by: actor)
    assert_not visit.complete_follow_up!(by: actor)
    assert_equal 1, visit.follow_up_events.where(action: "completed").count

    assert visit.reopen_follow_up!(by: actor)
    assert_not visit.reopen_follow_up!(by: actor)
    assert_equal 1, visit.follow_up_events.where(action: "reopened").count
  end

  test "one invalid photo adds one validation error and purges the attachment" do
    visit = create_service_visit
    visit.photos.attach(uploaded_photo("sample.pdf", "application/pdf"))
    invalid_blob_ids = visit.photos.attachments.map { |attachment| attachment.blob.id }

    assert_not visit.valid?
    assert_equal [ photo_upload_error ], visit.errors[:photos]
    visit.reload
    assert_not visit.photos.attached?
    assert invalid_blob_ids.none? { |blob_id| ActiveStorage::Blob.exists?(blob_id) }
  end

  test "multiple invalid photos add one validation error and purge invalid attachments" do
    visit = create_service_visit
    visit.photos.attach([
      uploaded_photo("sample.pdf", "application/pdf"),
      uploaded_photo("sample.exe", "application/x-msdownload")
    ])
    invalid_blob_ids = visit.photos.attachments.map { |attachment| attachment.blob.id }

    assert_not visit.valid?
    assert_equal [ photo_upload_error ], visit.errors[:photos]
    visit.reload
    assert_not visit.photos.attached?
    assert invalid_blob_ids.none? { |blob_id| ActiveStorage::Blob.exists?(blob_id) }
  end

  test "mixed valid and invalid photos preserve existing valid attachments" do
    visit = create_service_visit
    visit.photos.attach(uploaded_photo("sample.jpg", "image/jpeg"))
    visit.reload
    valid_blob_ids = visit.photos.attachments.map { |attachment| attachment.blob.id }

    visit.photos.attach([
      uploaded_photo("sample.pdf", "application/pdf"),
      uploaded_photo("sample.exe", "application/x-msdownload")
    ])

    assert_not visit.valid?
    assert_equal [ photo_upload_error ], visit.errors[:photos]
    visit.reload
    assert_equal valid_blob_ids, visit.photos.attachments.map { |attachment| attachment.blob.id }
    assert_equal [ "image/jpeg" ], visit.photos.map { |photo| photo.blob.content_type }
  end

  test "valid multiple photos are accepted" do
    visit = create_service_visit
    visit.photos.attach([
      uploaded_photo("sample.jpg", "image/jpeg"),
      uploaded_photo("sample.webp", "image/webp")
    ])

    assert visit.valid?
    assert_empty visit.errors[:photos]
    assert_equal [ "image/jpeg", "image/webp" ], visit.photos.map { |photo| photo.blob.content_type }
  end

  private

  def create_service_visit
    ServiceVisit.create!(asset: create_vessel, performed_by_user: create_user, visit_date: Date.current)
  end

  def uploaded_photo(filename, content_type)
    Rack::Test::UploadedFile.new(file_fixture(filename).to_s, content_type, true)
  end

  def photo_upload_error
    "must be JPEG, PNG, or WEBP images"
  end
end
