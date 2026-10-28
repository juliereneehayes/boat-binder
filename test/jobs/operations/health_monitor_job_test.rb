require "test_helper"

module Operations
  class HealthMonitorJobTest < ActiveJob::TestCase
    setup do
      @now = Time.zone.local(2026, 10, 27, 12)
      @cache_store = ActiveSupport::Cache::MemoryStore.new
      @previous_recipient = Rails.configuration.x.operations.alert_recipient
      Rails.configuration.x.operations.alert_recipient = "operator@example.test"
      ActionMailer::Base.deliveries.clear
      clear_enqueued_jobs
    end

    teardown do
      Rails.configuration.x.operations.alert_recipient = @previous_recipient
      ActionMailer::Base.deliveries.clear
      @cache_store.clear
      clear_enqueued_jobs
    end

    test "healthy system produces no alert" do
      assert_no_difference -> { ActionMailer::Base.deliveries.size } do
        perform_monitor
      end
    end

    test "failed execution produces one sanitized operator alert" do
      create_failed_execution(
        class_name: "Storage::AttachmentScanJob",
        failed_at: @now - 4.minutes,
        arguments: [ "private-filename.pdf", "gid://boat-binder/Document/123" ],
        exception_message: "bucket/key/private-filename.pdf"
      )

      logs = capture_logs do
        assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
          perform_monitor
        end
      end

      rendered = rendered_alert
      assert_includes rendered, "Storage::AttachmentScanJob"
      assert_includes rendered, "Failed background jobs: 1"
      assert_not_includes rendered, "private-filename.pdf"
      assert_not_includes rendered, "gid://boat-binder/Document/123"
      assert_not_includes rendered, "bucket/key"
      assert_not_includes rendered, "StandardError"
      assert_not_includes logs, "operator@example.test"
      assert_not_includes logs, "private-filename.pdf"
      assert_not_includes logs, "bucket/key"
    end

    test "repeated runs suppress an unchanged condition" do
      create_failed_execution(class_name: "Storage::AttachmentScanJob", failed_at: @now - 4.minutes)

      assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
        perform_monitor
      end
      assert_no_difference -> { ActionMailer::Base.deliveries.size } do
        perform_monitor(now: @now + 15.minutes)
      end
    end

    test "a materially new failure produces a new alert" do
      create_failed_execution(class_name: "Storage::AttachmentScanJob", failed_at: @now - 4.minutes)
      perform_monitor

      create_failed_execution(class_name: "Storage::PurgeUnattachedBlobsJob", failed_at: @now + 1.minute)

      assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
        perform_monitor(now: @now + 2.minutes)
      end
      assert_includes rendered_alert, "Storage::PurgeUnattachedBlobsJob"
    end

    test "stale pending scan beyond polling and recovery windows is surfaced without mutation" do
      scan = pending_scan(
        created_at: @now - Storage::AttachmentScanJob::POLL_WINDOW -
          HealthMonitorJob::STALE_SCAN_RECOVERY_GRACE - 1.minute
      )
      original_attributes = scan.attributes.slice("status", "check_count", "last_checked_at", "updated_at")

      assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
        perform_monitor
      end

      assert_includes rendered_alert, "Stale pending attachment scans: 1"
      assert_equal original_attributes,
        scan.reload.attributes.slice("status", "check_count", "last_checked_at", "updated_at")
    end

    test "pending scan inside the polling and recovery windows is healthy" do
      pending_scan(created_at: @now - Storage::AttachmentScanJob::POLL_WINDOW)

      assert_no_difference -> { ActionMailer::Base.deliveries.size } do
        perform_monitor
      end
    end

    test "failed attachment scan state is surfaced without exposing blob metadata" do
      scan = failed_scan(
        status_code: "ENQUEUE_FAILED",
        completed_at: @now - 3.minutes,
        filename: "private-customer-document.pdf"
      )
      original_attributes = scan.attributes.slice("status", "status_code", "completed_at", "updated_at")

      perform_monitor

      rendered = rendered_alert
      assert_includes rendered, "Failed attachment scans: 1"
      assert_includes rendered, "ENQUEUE_FAILED"
      assert_not_includes rendered, "private-customer-document.pdf"
      assert_not_includes rendered, scan.active_storage_blob.key
      assert_not_includes rendered, "active_storage_blob_id"
      assert_not_includes rendered, "blob_id"
      assert_equal original_attributes,
        scan.reload.attributes.slice("status", "status_code", "completed_at", "updated_at")
    end

    test "cleanup job failures use the general failed-job signal" do
      failure = create_failed_execution(
        class_name: "Storage::PurgeUnattachedBlobsJob",
        failed_at: @now - 2.minutes
      )

      perform_monitor

      assert_includes rendered_alert, "Storage::PurgeUnattachedBlobsJob"
      assert SolidQueue::FailedExecution.exists?(failure.id)
    end

    test "missing recipient configuration skips delivery and logs only safe categories" do
      Rails.configuration.x.operations.alert_recipient = nil
      create_failed_execution(
        class_name: "Storage::AttachmentScanJob",
        failed_at: @now - 2.minutes,
        arguments: [ "private-name.pdf" ],
        exception_message: "private provider detail"
      )

      logs = capture_logs do
        assert_no_difference -> { ActionMailer::Base.deliveries.size } do
          perform_monitor
        end
      end

      assert_includes logs, "reason=recipient_not_configured"
      assert_includes logs, "failed_background_jobs"
      assert_not_includes logs, "private-name.pdf"
      assert_not_includes logs, "private provider detail"
    end

    test "monitor failures are excluded from recursive failed-job alerts" do
      create_failed_execution(class_name: "Operations::HealthMonitorJob", failed_at: @now - 2.minutes)

      assert_no_difference -> { ActionMailer::Base.deliveries.size } do
        perform_monitor
      end
    end

    private

    def perform_monitor(now: @now)
      job = HealthMonitorJob.new
      cache_store = @cache_store
      job.define_singleton_method(:cache_store) { cache_store }
      job.perform(now:)
    end

    def create_failed_execution(class_name:, failed_at:, arguments: [], exception_message: "private failure detail")
      job = SolidQueue::Job.create!(
        queue_name: "background",
        class_name:,
        arguments: {
          "job_class" => class_name,
          "arguments" => arguments,
          "executions" => 1,
          "exception_executions" => {}
        },
        scheduled_at: failed_at,
        created_at: failed_at,
        updated_at: failed_at
      )
      job.ready_execution&.destroy!
      SolidQueue::FailedExecution.create!(
        job:,
        error: {
          "exception_class" => "StandardError",
          "message" => exception_message,
          "backtrace" => [ "/private/customer/path.rb:1" ]
        },
        created_at: failed_at
      )
    end

    def pending_scan(created_at:)
      create_scan(status: "pending", status_code: nil, completed_at: nil, created_at:)
    end

    def failed_scan(status_code:, completed_at:, filename: "scan.pdf")
      create_scan(
        status: "failed",
        status_code:,
        completed_at:,
        created_at: completed_at - 1.minute,
        filename:
      )
    end

    def create_scan(status:, status_code:, completed_at:, created_at:, filename: "scan.pdf")
      blob = ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new("fixture"),
        filename:,
        content_type: "application/pdf"
      )
      AttachmentScan.create!(
        active_storage_blob: blob,
        status:,
        provider: AttachmentScan::PROVIDER,
        status_code:,
        completed_at:,
        created_at:,
        updated_at: created_at
      ).tap { clear_enqueued_jobs }
    end

    def rendered_alert
      mail = ActionMailer::Base.deliveries.last
      [ mail.subject, mail.text_part.decoded, mail.html_part.decoded ].join(" ")
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
