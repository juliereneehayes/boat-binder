require "test_helper"

module Operations
  class HealthMonitorJobTest < ActiveJob::TestCase
    class CacheDouble
      attr_reader :writes

      def initialize(read_error: nil, write_error: nil)
        @read_error = read_error
        @write_error = write_error
        @writes = []
      end

      def exist?(_key)
        raise @read_error if @read_error

        false
      end

      def write(key, value, **options)
        raise @write_error if @write_error

        @writes << [ key, value, options ]
        true
      end
    end

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
        ActionMailer::Base.logger.info("mailer_logger_capture=active")
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
      assert_includes logs, "mailer_logger_capture=active"
      assert_not_includes logs, "operator@example.test"
      assert_not_includes logs, "private-filename.pdf"
      assert_not_includes logs, "bucket/key"
    end

    test "count buckets alert on growth boundaries and suppress ordinary count churn" do
      create_failed_execution(class_name: "Storage::AttachmentScanJob", failed_at: @now - 4.minutes)

      assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
        perform_monitor
      end

      add_failed_executions(1, starting_at: @now + 1.minute)
      assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
        perform_monitor(now: @now + 2.minutes)
      end

      add_failed_executions(6, starting_at: @now + 3.minutes)
      assert_no_difference -> { ActionMailer::Base.deliveries.size } do
        perform_monitor(now: @now + 4.minutes)
      end

      add_failed_executions(2, starting_at: @now + 5.minutes)
      assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
        perform_monitor(now: @now + 6.minutes)
      end

      add_failed_executions(65, starting_at: @now + 7.minutes)
      assert_no_difference -> { ActionMailer::Base.deliveries.size } do
        perform_monitor(now: @now + 8.minutes)
      end

      add_failed_executions(25, starting_at: @now + 9.minutes)
      assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
        perform_monitor(now: @now + 10.minutes)
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

    test "a new attachment failure status category produces a new alert" do
      failed_scan(status_code: "FAILED", completed_at: @now - 4.minutes)
      perform_monitor

      failed_scan(status_code: "ENQUEUE_FAILED", completed_at: @now + 1.minute)

      assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
        perform_monitor(now: @now + 2.minutes)
      end
      assert_includes rendered_alert, "ENQUEUE_FAILED"
    end

    test "recent failed attachment scan alerts" do
      failed_scan(status_code: "FAILED", completed_at: @now - 1.minute)

      assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
        perform_monitor
      end
      assert_includes rendered_alert, "Failed attachment scans: 1"
    end

    test "failed attachment scan inside the lookback alerts" do
      failed_scan(
        status_code: "FAILED",
        completed_at: @now - HealthMonitorJob::FAILED_SCAN_ALERT_LOOKBACK + 1.second
      )

      assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
        perform_monitor
      end
    end

    test "failed attachment scan older than the lookback does not alert" do
      failed_scan(
        status_code: "FAILED",
        completed_at: @now - HealthMonitorJob::FAILED_SCAN_ALERT_LOOKBACK - 1.second
      )

      assert_no_difference -> { ActionMailer::Base.deliveries.size } do
        perform_monitor
      end
    end

    test "failed attachment scan at the exact lookback boundary alerts" do
      failed_scan(
        status_code: "FAILED",
        completed_at: @now - HealthMonitorJob::FAILED_SCAN_ALERT_LOOKBACK
      )

      assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
        perform_monitor
      end
    end

    test "aging out of failed scan alerts does not modify scan state or availability" do
      scan = failed_scan(
        status_code: "FAILED",
        completed_at: @now - HealthMonitorJob::FAILED_SCAN_ALERT_LOOKBACK + 1.second
      )
      original_attributes = scan.attributes

      perform_monitor

      assert_no_difference -> { ActionMailer::Base.deliveries.size } do
        perform_monitor(now: @now + 2.seconds)
      end
      assert_equal original_attributes, scan.reload.attributes
      assert_not scan.available?
    end

    test "failed attachment scan with nil completion time uses recent update time safely" do
      scan = create_scan(
        status: "failed",
        status_code: "FAILED",
        completed_at: nil,
        created_at: @now - 1.minute
      )
      original_attributes = scan.attributes

      assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
        perform_monitor
      end
      assert_equal original_attributes, scan.reload.attributes
      assert_not scan.available?
    end

    test "failed attachment scan with nil completion time ages out by update time" do
      scan = create_scan(
        status: "failed",
        status_code: "FAILED",
        completed_at: nil,
        created_at: @now - HealthMonitorJob::FAILED_SCAN_ALERT_LOOKBACK - 1.second
      )
      original_attributes = scan.attributes

      assert_no_difference -> { ActionMailer::Base.deliveries.size } do
        perform_monitor
      end
      assert_equal original_attributes, scan.reload.attributes
      assert_not scan.available?
    end

    test "unchanged conditions produce a reminder after 24 hours" do
      create_failed_execution(class_name: "Storage::AttachmentScanJob", failed_at: @now - 4.minutes)

      travel_to(@now) do
        perform_monitor(now: Time.current)
        travel HealthMonitorJob::ALERT_REMINDER_INTERVAL + 1.second

        assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
          perform_monitor(now: Time.current)
        end
      end
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

    test "pending scan exactly at the polling and recovery grace boundary is healthy" do
      pending_scan(
        created_at: @now - Storage::AttachmentScanJob::POLL_WINDOW -
          HealthMonitorJob::STALE_SCAN_RECOVERY_GRACE
      )

      assert_no_difference -> { ActionMailer::Base.deliveries.size } do
        perform_monitor
      end
    end

    test "unsafe job class is reported as UnknownJob" do
      create_failed_execution(class_name: "unsafe private filename.pdf", failed_at: @now - 2.minutes)

      perform_monitor

      assert_includes rendered_alert, "UnknownJob"
      assert_not_includes rendered_alert, "unsafe private filename.pdf"
    end

    test "unknown attachment scan status code is reported as UNKNOWN" do
      failed_scan(status_code: nil, completed_at: @now - 2.minutes)

      perform_monitor

      assert_includes rendered_alert, "UNKNOWN"
    end

    test "failed job classes are capped with the omitted count retained" do
      (HealthMonitorJob::MAX_FAILED_JOB_CLASSES + 2).times do |index|
        create_failed_execution(
          class_name: "Synthetic::FailureJob#{index}",
          failed_at: @now - index.seconds
        )
      end

      condition = health_conditions.fetch(0)

      assert_equal HealthMonitorJob::MAX_FAILED_JOB_CLASSES, condition.fetch(:groups).size
      assert_equal 2, condition.fetch(:omitted_job_class_count)
      perform_monitor
      assert_includes rendered_alert, "Additional job classes omitted: 2"

      create_failed_execution(class_name: "Synthetic::FailureJob26", failed_at: @now + 1.minute)
      assert_no_difference -> { ActionMailer::Base.deliveries.size } do
        perform_monitor(now: @now + 2.minutes)
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

    test "a prior monitor failure is surfaced by a later successful monitor run" do
      create_failed_execution(class_name: "Operations::HealthMonitorJob", failed_at: @now - 2.minutes)

      assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
        perform_monitor
      end
      assert_includes rendered_alert, "Operations::HealthMonitorJob"
    end

    test "SMTP failure writes no fingerprint logs only its class and retries next run" do
      create_failed_execution(class_name: "Storage::AttachmentScanJob", failed_at: @now - 2.minutes)
      cache_key = alert_cache_key
      failing_message = Object.new
      failing_message.define_singleton_method(:deliver_now) do
        raise IOError, "private SMTP provider detail"
      end

      logs = capture_logs do
        with_mailer_health_alert(->(**) { failing_message }) do
          assert_no_difference -> { ActionMailer::Base.deliveries.size } do
            perform_monitor
          end
        end
      end

      assert_not @cache_store.exist?(cache_key)
      assert_includes logs, "result=delivery_failed exception_class=IOError"
      assert_not_includes logs, "private SMTP provider detail"
      assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
        perform_monitor(now: @now + 15.minutes)
      end
    end

    test "cache read failure fails open and logs only its class" do
      create_failed_execution(class_name: "Storage::AttachmentScanJob", failed_at: @now - 2.minutes)
      store = CacheDouble.new(read_error: IOError.new("private cache read detail"))

      logs = capture_logs do
        assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
          perform_monitor(cache_store: store)
        end
      end

      assert_equal 1, store.writes.size
      assert_includes logs, "cache result=read_failed exception_class=IOError"
      assert_not_includes logs, "private cache read detail"
    end

    test "cache write failure preserves delivery and allows a later duplicate" do
      create_failed_execution(class_name: "Storage::AttachmentScanJob", failed_at: @now - 2.minutes)
      store = CacheDouble.new(write_error: IOError.new("private cache write detail"))

      logs = capture_logs do
        assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
          perform_monitor(cache_store: store)
        end
      end

      assert_includes logs, "cache result=write_failed exception_class=IOError"
      assert_not_includes logs, "private cache write detail"
      assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
        perform_monitor(cache_store: store, now: @now + 15.minutes)
      end
    end

    private

    def perform_monitor(now: @now, cache_store: @cache_store)
      job = HealthMonitorJob.new
      job.define_singleton_method(:cache_store) { cache_store }
      job.perform(now:)
    end

    def health_conditions(now: @now)
      HealthMonitorJob.new.send(:health_conditions, now:)
    end

    def alert_cache_key(now: @now)
      HealthMonitorJob.new.send(:alert_cache_key, health_conditions(now:))
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

    def add_failed_executions(count, class_name: "Storage::AttachmentScanJob", starting_at:)
      count.times do |index|
        create_failed_execution(class_name:, failed_at: starting_at + index.seconds)
      end
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
      previous_mailer_logger = ActionMailer::Base.logger
      output = StringIO.new
      logger = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(output))
      Rails.logger = logger
      ActionMailer::Base.logger = logger
      yield
      output.string
    ensure
      Rails.logger = previous_logger
      ActionMailer::Base.logger = previous_mailer_logger
    end

    def with_mailer_health_alert(replacement)
      original = OperationalAlertsMailer.method(:health_alert)
      OperationalAlertsMailer.define_singleton_method(:health_alert) do |**arguments|
        replacement.call(**arguments)
      end
      yield
    ensure
      OperationalAlertsMailer.define_singleton_method(:health_alert, original)
    end
  end
end
