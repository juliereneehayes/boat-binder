require "test_helper"

module Storage
  class RecoverStaleAttachmentScansJobTest < ActiveJob::TestCase
    setup do
      @now = Time.zone.local(2026, 10, 24, 12)
      clear_enqueued_jobs
    end

    teardown do
      clear_enqueued_jobs
    end

    test "stale pending scans fail closed with safe observable timeout details" do
      scan = pending_scan(created_at: @now - AttachmentScanJob::POLL_WINDOW - 1.second)

      logs = capture_logs do
        assert_raises(RecoverStaleAttachmentScansJob::TerminalRecoveryError) do
          RecoverStaleAttachmentScansJob.perform_now(now: @now)
        end
      end

      assert_equal "failed", scan.reload.status
      assert_equal "SCAN_TIMEOUT", scan.status_code
      assert_equal @now, scan.completed_at
      assert_includes logs, "scan_id=#{scan.id}"
      assert_includes logs, "blob_id=#{scan.active_storage_blob_id}"
      assert_includes logs, "status_code=SCAN_TIMEOUT"
      assert_not_includes logs, scan.active_storage_blob.filename.to_s
      assert_not_includes logs, scan.active_storage_blob.key
    end

    test "fresh pending scans remain unchanged" do
      scan = pending_scan(created_at: @now - AttachmentScanJob::POLL_WINDOW + 1.second)

      RecoverStaleAttachmentScansJob.perform_now(now: @now)

      assert_equal "pending", scan.reload.status
      assert_nil scan.status_code
      assert_nil scan.completed_at
    end

    test "terminal states remain unchanged" do
      scans = {
        "clean" => "NO_THREATS_FOUND",
        "rejected" => "THREATS_FOUND",
        "failed" => "FAILED",
        "trusted_existing" => "ROLLOUT_BACKFILL"
      }.map do |status, status_code|
        create_scan(status:, status_code:, created_at: @now - 1.hour)
      end
      original_attributes = scans.index_with { |scan| scan.attributes.slice("status", "status_code", "completed_at", "updated_at") }

      RecoverStaleAttachmentScansJob.perform_now(now: @now)

      scans.each do |scan|
        assert_equal original_attributes.fetch(scan),
          scan.reload.attributes.slice("status", "status_code", "completed_at", "updated_at")
      end
    end

    test "a late terminal transition is not overwritten" do
      scan = pending_scan(created_at: @now - 1.hour)
      completion_time = @now - 1.second
      candidates = Object.new
      candidates.define_singleton_method(:find_each) do |&block|
        scan.mark_clean!(completed_at: completion_time)
        block.call(scan)
      end
      job = RecoverStaleAttachmentScansJob.new
      job.define_singleton_method(:stale_pending_scans) { |now:| candidates }

      job.perform(now: @now)

      assert_equal "clean", scan.reload.status
      assert_equal "NO_THREATS_FOUND", scan.status_code
      assert_equal completion_time, scan.completed_at
    end

    test "repeated recovery runs are idempotent" do
      scan = pending_scan(created_at: @now - 1.hour)

      assert_raises(RecoverStaleAttachmentScansJob::TerminalRecoveryError) do
        RecoverStaleAttachmentScansJob.perform_now(now: @now)
      end
      first_result = scan.reload.attributes.slice("status", "status_code", "completed_at", "updated_at")

      RecoverStaleAttachmentScansJob.perform_now(now: @now + 5.minutes)

      assert_equal first_result,
        scan.reload.attributes.slice("status", "status_code", "completed_at", "updated_at")
    end

    private

    def pending_scan(created_at:)
      scan = create_scan(status: "pending", status_code: nil, created_at:)
      clear_enqueued_jobs
      scan
    end

    def create_scan(status:, status_code:, created_at:)
      blob = ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new("fixture"),
        filename: "private-name.pdf",
        content_type: "application/pdf"
      )
      AttachmentScan.create!(
        active_storage_blob: blob,
        status:,
        provider: AttachmentScan::PROVIDER,
        status_code:,
        completed_at: status == "pending" ? nil : created_at,
        created_at:,
        updated_at: created_at
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
end
