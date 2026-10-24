module Storage
  class AttachmentScanJob < ApplicationJob
    queue_as :background

    INITIAL_POLL_INTERVALS = [ 5.seconds, 10.seconds, 15.seconds, 30.seconds ].freeze
    POLL_INTERVAL = 1.minute
    POLL_WINDOW = 15.minutes

    TerminalScanError = Class.new(StandardError)
    ScanStateLoadError = Class.new(StandardError)

    def perform(scan_id, now: Time.current)
      scan = AttachmentScan.find_by(id: scan_id)
      return unless scan&.status == "pending"
      return unless scan.record_check!(checked_at: now)

      apply_provider_status(scan, GuardDutyMalwareScanStatus.read(scan.active_storage_blob), now:)
    rescue GuardDutyMalwareScanStatus::UnsupportedServiceError => error
      fail_terminal!(scan, "UNSUPPORTED_SERVICE", error)
    rescue Aws::S3::Errors::ServiceError => error
      retry_or_fail!(scan, now:, error:)
    rescue TerminalScanError
      raise
    rescue StandardError => error
      unless scan
        Rails.logger.error(
          "Attachment scan state load failed scan_id=#{scan_id} " \
          "exception_class=#{error.class.name}"
        )
        raise ScanStateLoadError, "attachment scan state could not be loaded"
      end

      retry_or_fail!(scan, now:, error:)
    end

    private

    def apply_provider_status(scan, provider_status, now:)
      case provider_status
      when "NO_THREATS_FOUND"
        scan.mark_clean!(completed_at: now)
      when "THREATS_FOUND"
        scan.mark_rejected!(completed_at: now)
      when "UNSUPPORTED", "ACCESS_DENIED", "FAILED"
        fail_terminal!(scan, provider_status)
      when nil
        retry_or_fail!(scan, now:)
      else
        fail_terminal!(scan, "UNKNOWN")
      end
    end

    def retry_or_fail!(scan, now:, error: nil)
      return unless scan&.reload&.status == "pending"

      if now < scan.created_at + POLL_WINDOW
        enqueue_next_poll!(scan, now:)
        log_provider_retry(scan, error) if error
        return
      end

      code = error ? "PROVIDER_ERROR" : "SCAN_TIMEOUT"
      fail_terminal!(scan, code, error)
    end

    def enqueue_next_poll!(scan, now:)
      enqueued_job = self.class.set(wait: next_poll_interval(scan, now:)).perform_later(scan.id)
      return enqueued_job if enqueued_job

      fail_terminal!(scan, "ENQUEUE_FAILED", ActiveJob::EnqueueError.new)
    rescue TerminalScanError
      raise
    rescue StandardError => error
      fail_terminal!(scan, "ENQUEUE_FAILED", error)
    end

    def next_poll_interval(scan, now:)
      cadence_interval = INITIAL_POLL_INTERVALS.fetch(scan.check_count - 1, POLL_INTERVAL)
      remaining_interval = scan.created_at + POLL_WINDOW - now

      [ cadence_interval.to_f, remaining_interval ].min.seconds
    end

    def log_provider_retry(scan, error)
      Rails.logger.warn(
        "Attachment scan provider retry scan_id=#{scan.id} " \
        "blob_id=#{scan.active_storage_blob_id} exception_class=#{error.class.name} " \
        "next_poll_scheduled=true"
      )
    end

    def fail_terminal!(scan, status_code, error = nil)
      transitioned = scan&.mark_failed!(status_code:)
      return unless transitioned

      Rails.logger.error(
        "Attachment scan failed scan_id=#{scan.id} blob_id=#{scan.active_storage_blob_id} " \
        "status_code=#{status_code} exception_class=#{error&.class&.name || 'none'}"
      )
      raise TerminalScanError, "attachment scan failed with #{status_code}"
    end
  end
end
