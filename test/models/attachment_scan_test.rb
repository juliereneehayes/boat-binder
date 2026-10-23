require "test_helper"

class AttachmentScanTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    clear_enqueued_jobs
    @blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("safe fixture"),
      filename: "fixture.pdf",
      content_type: "application/pdf"
    )
  end

  teardown do
    clear_enqueued_jobs
  end

  test "pending registration is unique idempotent and enqueues one scan" do
    assert_enqueued_jobs 1, only: Storage::AttachmentScanJob do
      first = AttachmentScan.register_pending!(@blob)
      second = AttachmentScan.register_pending!(@blob)

      assert_equal first, second
      assert_equal "pending", first.status
      assert_equal AttachmentScan::PROVIDER, first.provider
    end

    assert_equal 1, AttachmentScan.where(active_storage_blob: @blob).count
  end

  test "only clean and rollout-grandfathered scans are available" do
    %w[pending rejected failed].each do |status|
      scan = build_scan(status:)
      refute scan.available?, status
    end

    %w[clean trusted_existing].each do |status|
      scan = build_scan(status:)
      assert scan.available?, status
    end
  end

  test "rejection creates exactly one minimized audit event" do
    scan = AttachmentScan.register_pending!(@blob)

    assert_difference -> { SecurityAuditEvent.count }, 1 do
      assert scan.mark_rejected!
      refute scan.mark_rejected!
    end

    event = SecurityAuditEvent.unscoped.order(:id).last
    assert_equal "attachment.malware_rejected", event.action
    assert_equal "denied", event.outcome
    assert_equal "AttachmentScan", event.target_type
    assert_equal scan.id, event.target_id
    assert_nil event.account_id
    assert_nil event.actor_user_id
    assert_empty event.changed_fields
    assert_equal "THREATS_FOUND", scan.reload.status_code
    serialized_event = event.attributes.to_json
    assert_not_includes serialized_event, @blob.filename.to_s
    assert_not_includes serialized_event, @blob.key
    assert_not_includes serialized_event, "safe fixture"
  end

  test "terminal states cannot be reopened by duplicate workers" do
    scan = AttachmentScan.register_pending!(@blob)
    assert scan.mark_clean!

    refute scan.mark_failed!(status_code: "FAILED")
    refute scan.mark_rejected!
    assert_equal "clean", scan.reload.status
  end

  test "enqueue failures leave the upload unavailable and log only safe identifiers" do
    original = Storage::AttachmentScanJob.method(:perform_later)
    Storage::AttachmentScanJob.define_singleton_method(:perform_later) do |*_arguments|
      raise IOError, "private queue detail"
    end

    logs = capture_logs do
      @scan = AttachmentScan.register_pending!(@blob)
    end

    assert_equal "failed", @scan.reload.status
    assert_equal "ENQUEUE_FAILED", @scan.status_code
    assert_includes logs, "scan_id=#{@scan.id}"
    assert_includes logs, "blob_id=#{@blob.id}"
    assert_includes logs, "exception_class=IOError"
    assert_not_includes logs, "private queue detail"
    assert_not_includes logs, @blob.filename.to_s
    assert_not_includes logs, @blob.key
  ensure
    Storage::AttachmentScanJob.define_singleton_method(:perform_later, original) if original
  end

  private

  def build_scan(status:)
    AttachmentScan.new(
      active_storage_blob: @blob,
      status:,
      provider: AttachmentScan::PROVIDER
    )
  end

  def capture_logs
    previous_logger = Rails.logger
    output = StringIO.new
    Rails.logger = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(output))
    yield
    output.string
  ensure
    Rails.logger = previous_logger
  end
end
