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

    test "stale pending with a clean provider result becomes clean" do
      scan = pending_scan(created_at: @now - AttachmentScanJob::POLL_WINDOW - 1.second)

      with_provider_status("NO_THREATS_FOUND") do
        assert_no_enqueued_jobs do
          RecoverStaleAttachmentScansJob.perform_now(now: @now)
        end
      end

      assert_equal "clean", scan.reload.status
      assert_equal "NO_THREATS_FOUND", scan.status_code
      assert_equal 1, scan.check_count
    end

    test "stale pending with a threat result becomes rejected" do
      scan = pending_scan(created_at: @now - AttachmentScanJob::POLL_WINDOW - 1.second)

      with_provider_status("THREATS_FOUND") do
        assert_no_enqueued_jobs do
          assert_difference -> { SecurityAuditEvent.where(action: "attachment.malware_rejected").count }, 1 do
            RecoverStaleAttachmentScansJob.perform_now(now: @now)
          end
        end
      end

      assert_equal "rejected", scan.reload.status
      assert_equal "THREATS_FOUND", scan.status_code
    end

    test "stale pending with a still-missing result fails closed as a timeout" do
      scan = pending_scan(created_at: @now - AttachmentScanJob::POLL_WINDOW - 1.second)

      logs = capture_logs do
        with_provider_status(nil) do
          assert_no_enqueued_jobs do
            assert_raises(RecoverStaleAttachmentScansJob::TerminalRecoveryError) do
              RecoverStaleAttachmentScansJob.perform_now(now: @now)
            end
          end
        end
      end

      assert_equal "failed", scan.reload.status
      assert_equal "SCAN_TIMEOUT", scan.status_code
      assert scan.completed_at
      assert_includes logs, "scan_id=#{scan.id}"
      assert_includes logs, "blob_id=#{scan.active_storage_blob_id}"
      assert_includes logs, "status_code=SCAN_TIMEOUT"
      assert_not_includes logs, scan.active_storage_blob.filename.to_s
      assert_not_includes logs, scan.active_storage_blob.key
    end

    test "a terminal reconciliation does not stop later stale scans" do
      timed_out_scan = pending_scan(created_at: @now - 1.hour)
      clean_scan = pending_scan(created_at: @now - 1.hour)
      reader = lambda do |blob|
        blob.id == timed_out_scan.active_storage_blob_id ? nil : "NO_THREATS_FOUND"
      end

      with_provider_reader(reader) do
        assert_no_enqueued_jobs do
          assert_raises(RecoverStaleAttachmentScansJob::TerminalRecoveryError) do
            RecoverStaleAttachmentScansJob.perform_now(now: @now)
          end
        end
      end

      assert_equal "failed", timed_out_scan.reload.status
      assert_equal "SCAN_TIMEOUT", timed_out_scan.status_code
      assert_equal "clean", clean_scan.reload.status
      assert_equal "NO_THREATS_FOUND", clean_scan.status_code
    end

    test "fresh pending scans remain unchanged" do
      scan = pending_scan(created_at: @now - AttachmentScanJob::POLL_WINDOW + 1.second)

      with_provider_reader(->(_blob) { raise "fresh scan must not be reconciled" }) do
        RecoverStaleAttachmentScansJob.perform_now(now: @now)
      end

      assert_equal "pending", scan.reload.status
      assert_nil scan.status_code
      assert_nil scan.completed_at
      assert_equal 0, scan.check_count
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
      original_attributes = scans.index_with do |scan|
        scan.attributes.slice("status", "status_code", "completed_at", "updated_at")
      end

      with_provider_reader(->(_blob) { raise "terminal scan must not be reconciled" }) do
        RecoverStaleAttachmentScansJob.perform_now(now: @now)
      end

      scans.each do |scan|
        assert_equal original_attributes.fetch(scan),
          scan.reload.attributes.slice("status", "status_code", "completed_at", "updated_at")
      end
    end

    test "a concurrent terminal transition is not overwritten" do
      scan = pending_scan(created_at: @now - 1.hour)
      completion_time = @now - 1.second
      candidates = Object.new
      candidates.define_singleton_method(:find_each) do |&block|
        scan.mark_clean!(completed_at: completion_time)
        block.call(scan)
      end
      job = RecoverStaleAttachmentScansJob.new
      job.define_singleton_method(:stale_pending_scans) { |now:| candidates }

      with_provider_reader(->(_blob) { raise "terminal scan must not be reconciled" }) do
        job.perform(now: @now)
      end

      assert_equal "clean", scan.reload.status
      assert_equal "NO_THREATS_FOUND", scan.status_code
      assert_equal completion_time, scan.completed_at
    end

    test "repeated recovery runs are idempotent" do
      scan = pending_scan(created_at: @now - 1.hour)

      with_provider_status(nil) do
        assert_raises(RecoverStaleAttachmentScansJob::TerminalRecoveryError) do
          RecoverStaleAttachmentScansJob.perform_now(now: @now)
        end
      end
      first_result = scan.reload.attributes.slice("status", "status_code", "completed_at", "updated_at")

      with_provider_reader(->(_blob) { raise "terminal scan must not be reconciled again" }) do
        RecoverStaleAttachmentScansJob.perform_now(now: @now + 5.minutes)
      end

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

    def with_provider_status(status)
      with_provider_reader(->(_blob) { status }) { yield }
    end

    def with_provider_reader(reader)
      original = GuardDutyMalwareScanStatus.method(:read)
      GuardDutyMalwareScanStatus.define_singleton_method(:read, reader)
      yield
    ensure
      GuardDutyMalwareScanStatus.define_singleton_method(:read, original)
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
