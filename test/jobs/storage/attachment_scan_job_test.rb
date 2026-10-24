require "test_helper"
require "active_storage/service/s3_service"

module Storage
  class AttachmentScanJobTest < ActiveJob::TestCase
    setup do
      @blob = ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new("safe fixture"),
        filename: "private-name.pdf",
        content_type: "application/pdf"
      )
      @scan = AttachmentScan.register_pending!(@blob)
      clear_enqueued_jobs
    end

    teardown do
      clear_enqueued_jobs
    end

    test "maps the exact clean provider status and records the check" do
      with_provider_status("NO_THREATS_FOUND") do
        AttachmentScanJob.perform_now(@scan.id)
      end

      assert_equal "clean", @scan.reload.status
      assert_equal "NO_THREATS_FOUND", @scan.status_code
      assert_equal 1, @scan.check_count
      assert @scan.last_checked_at
      assert @scan.completed_at
      refute SecurityAuditEvent.where(action: "attachment.malware_rejected").exists?
    end

    test "maps threats found to rejected and audits once across duplicate jobs" do
      with_provider_status("THREATS_FOUND") do
        assert_difference -> { SecurityAuditEvent.where(action: "attachment.malware_rejected").count }, 1 do
          AttachmentScanJob.perform_now(@scan.id)
          AttachmentScanJob.perform_now(@scan.id)
        end
      end

      assert_equal "rejected", @scan.reload.status
      assert_equal "THREATS_FOUND", @scan.status_code
    end

    test "maps provider failure statuses and unknown values to failed" do
      {
        "UNSUPPORTED" => "UNSUPPORTED",
        "ACCESS_DENIED" => "ACCESS_DENIED",
        "FAILED" => "FAILED",
        "FUTURE_PROVIDER_VALUE" => "UNKNOWN"
      }.each do |provider_status, expected_code|
        scan = pending_scan
        with_provider_status(provider_status) do
          assert_raises(AttachmentScanJob::TerminalScanError) do
            AttachmentScanJob.perform_now(scan.id)
          end
        end
        assert_equal "failed", scan.reload.status
        assert_equal expected_code, scan.status_code
      end
    end

    test "terminal failures have no application retry or discard handler" do
      assert_empty ApplicationJob.rescue_handlers
      assert_empty AttachmentScanJob.rescue_handlers
      error = AttachmentScanJob::TerminalScanError.new
      assert_nil AttachmentScanJob.new.handler_for_rescue(error)

      with_provider_status("FAILED") do
        assert_no_enqueued_jobs do
          assert_raises(AttachmentScanJob::TerminalScanError) do
            AttachmentScanJob.perform_now(@scan.id)
          end
        end
      end

      assert_equal "failed", @scan.reload.status
      assert_equal "FAILED", @scan.status_code
    end

    test "absent status stays pending and schedules a bounded poll" do
      logs = capture_logs do
        with_provider_status(nil) do
          assert_enqueued_jobs 1, only: AttachmentScanJob do
            AttachmentScanJob.perform_now(@scan.id, now: @scan.created_at + 1.minute)
          end
        end
      end

      assert_equal "pending", @scan.reload.status
      assert_equal 1, @scan.check_count
      assert_nil @scan.completed_at
      assert_not_includes logs, "Attachment scan provider retry"
    end

    test "missing status uses the bounded fast polling cadence before one minute polling" do
      waits = []
      scheduled_job = Object.new
      scheduled_job.define_singleton_method(:perform_later) { |*_arguments| true }
      original_set = AttachmentScanJob.method(:set)
      AttachmentScanJob.define_singleton_method(:set) do |**options|
        waits << options.fetch(:wait)
        scheduled_job
      end

      with_provider_status(nil) do
        [ 0.seconds, 5.seconds, 15.seconds, 30.seconds, 1.minute, 2.minutes ].each do |elapsed|
          AttachmentScanJob.perform_now(@scan.id, now: @scan.created_at + elapsed)
        end
      end

      assert_equal [ 5, 10, 15, 30, 60, 60 ], waits.map(&:to_i)
      assert_equal 6, @scan.reload.check_count
      assert_equal "pending", @scan.status
    ensure
      AttachmentScanJob.define_singleton_method(:set, original_set) if original_set
    end

    test "the next poll is capped at the existing fifteen minute deadline" do
      wait = nil
      scheduled_job = Object.new
      scheduled_job.define_singleton_method(:perform_later) { |*_arguments| true }
      original_set = AttachmentScanJob.method(:set)
      AttachmentScanJob.define_singleton_method(:set) do |**options|
        wait = options.fetch(:wait)
        scheduled_job
      end

      with_provider_status(nil) do
        AttachmentScanJob.perform_now(
          @scan.id,
          now: @scan.created_at + AttachmentScanJob::POLL_WINDOW - 2.seconds
        )
      end

      assert_equal 2, wait.to_i
      assert_equal "pending", @scan.reload.status
    ensure
      AttachmentScanJob.define_singleton_method(:set, original_set) if original_set
    end

    test "absent status fails after the polling window and remains observable" do
      logs = capture_logs do
        with_provider_status(nil) do
          assert_raises(AttachmentScanJob::TerminalScanError) do
            AttachmentScanJob.perform_now(@scan.id, now: @scan.created_at + AttachmentScanJob::POLL_WINDOW)
          end
        end
      end

      assert_equal "failed", @scan.reload.status
      assert_equal "SCAN_TIMEOUT", @scan.status_code
      assert_includes logs, "scan_id=#{@scan.id}"
      assert_includes logs, "blob_id=#{@blob.id}"
      assert_not_includes logs, @blob.filename.to_s
      assert_not_includes logs, @blob.key
    end

    test "provider API errors retry only inside the polling window with safe logging" do
      error = Aws::S3::Errors::ServiceError.new(nil, "private provider detail")

      retry_logs = capture_logs do
        with_provider_reader(->(_blob) { raise error }) do
          assert_enqueued_jobs 1, only: AttachmentScanJob do
            AttachmentScanJob.perform_now(@scan.id, now: @scan.created_at + 1.minute)
          end
        end
      end
      assert_equal "pending", @scan.reload.status
      assert_includes retry_logs, "scan_id=#{@scan.id}"
      assert_includes retry_logs, "blob_id=#{@blob.id}"
      assert_includes retry_logs, "exception_class=Aws::S3::Errors::ServiceError"
      assert_includes retry_logs, "next_poll_scheduled=true"
      assert_not_includes retry_logs, "private provider detail"
      assert_not_includes retry_logs, @blob.filename.to_s
      assert_not_includes retry_logs, @blob.key

      clear_enqueued_jobs
      logs = capture_logs do
        with_provider_reader(->(_blob) { raise error }) do
          assert_raises(AttachmentScanJob::TerminalScanError) do
            AttachmentScanJob.perform_now(
              @scan.id,
              now: @scan.created_at + AttachmentScanJob::POLL_WINDOW
            )
          end
        end
      end

      assert_equal "failed", @scan.reload.status
      assert_equal "PROVIDER_ERROR", @scan.status_code
      assert_not_includes logs, "private provider detail"
      assert_not_includes logs, @blob.filename.to_s
      assert_not_includes logs, @blob.key
    end

    test "development Disk scanning follows the normal simulated-clean transition" do
      environment = ActiveSupport::EnvironmentInquirer.new("development")
      original = Rails.method(:env)
      Rails.define_singleton_method(:env) { environment }

      AttachmentScanJob.perform_now(@scan.id)

      assert_equal "clean", @scan.reload.status
      assert_equal "NO_THREATS_FOUND", @scan.status_code
      assert_equal 1, @scan.check_count
    ensure
      Rails.define_singleton_method(:env, original) if original
    end

    test "unsupported storage fails closed without attempting an unbounded retry" do
      assert_raises(AttachmentScanJob::TerminalScanError) do
        AttachmentScanJob.perform_now(@scan.id)
      end

      assert_equal "failed", @scan.reload.status
      assert_equal "UNSUPPORTED_SERVICE", @scan.status_code
      assert_enqueued_jobs 0
    end

    test "terminal scans never read the provider or enqueue another poll" do
      {
        "clean" => "NO_THREATS_FOUND",
        "rejected" => "THREATS_FOUND",
        "failed" => "FAILED",
        "trusted_existing" => "ROLLOUT_BACKFILL"
      }.each do |status, status_code|
        scan = pending_scan
        scan.update!(status:, status_code:, completed_at: Time.current)

        with_provider_reader(->(_blob) { raise "terminal scan must not read provider state" }) do
          assert_no_enqueued_jobs { AttachmentScanJob.perform_now(scan.id) }
        end
      end
    end

    test "failure to enqueue the next poll becomes a terminal observable failure" do
      scheduled_job = Object.new
      scheduled_job.define_singleton_method(:perform_later) do |*_arguments|
        raise IOError, "private queue detail"
      end
      original_set = AttachmentScanJob.method(:set)
      AttachmentScanJob.define_singleton_method(:set) { |**_options| scheduled_job }

      logs = capture_logs do
        with_provider_status(nil) do
          assert_raises(AttachmentScanJob::TerminalScanError) do
            AttachmentScanJob.perform_now(@scan.id, now: @scan.created_at + 1.minute)
          end
        end
      end

      assert_equal "failed", @scan.reload.status
      assert_equal "ENQUEUE_FAILED", @scan.status_code
      assert_includes logs, "exception_class=IOError"
      assert_not_includes logs, "private queue detail"
      assert_not_includes logs, @blob.filename.to_s
      assert_not_includes logs, @blob.key
    ensure
      AttachmentScanJob.define_singleton_method(:set, original_set) if original_set
    end

    test "a false enqueue result fails closed instead of claiming a scheduled retry" do
      scheduled_job = Object.new
      scheduled_job.define_singleton_method(:perform_later) { |*_arguments| false }
      original_set = AttachmentScanJob.method(:set)
      AttachmentScanJob.define_singleton_method(:set) { |**_options| scheduled_job }

      logs = capture_logs do
        with_provider_status(nil) do
          assert_raises(AttachmentScanJob::TerminalScanError) do
            AttachmentScanJob.perform_now(@scan.id, now: @scan.created_at + 1.minute)
          end
        end
      end

      assert_equal "failed", @scan.reload.status
      assert_equal "ENQUEUE_FAILED", @scan.status_code
      assert_not_includes logs, "next_poll_scheduled=true"
    ensure
      AttachmentScanJob.define_singleton_method(:set, original_set) if original_set
    end

    test "scan-state load failures are not swallowed or logged with raw details" do
      original_find_by = AttachmentScan.method(:find_by)
      AttachmentScan.define_singleton_method(:find_by) do |*_arguments|
        raise IOError, "private database detail"
      end

      logs = capture_logs do
        assert_raises(AttachmentScanJob::ScanStateLoadError) do
          AttachmentScanJob.perform_now(@scan.id)
        end
      end

      assert_includes logs, "scan_id=#{@scan.id}"
      assert_includes logs, "exception_class=IOError"
      assert_not_includes logs, "private database detail"
      assert_equal "pending", @scan.reload.status
    ensure
      AttachmentScan.define_singleton_method(:find_by, original_find_by) if original_find_by
    end

    private

    def pending_scan
      blob = ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new("fixture"),
        filename: "fixture.pdf",
        content_type: "application/pdf"
      )
      AttachmentScan.register_pending!(blob).tap { clear_enqueued_jobs }
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
