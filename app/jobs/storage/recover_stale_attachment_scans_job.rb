module Storage
  class RecoverStaleAttachmentScansJob < ApplicationJob
    queue_as :background

    TerminalRecoveryError = Class.new(StandardError)

    def perform(now: Time.current)
      recovered_count = 0

      stale_pending_scans(now:).find_each do |scan|
        next unless scan.mark_failed!(status_code: "SCAN_TIMEOUT", completed_at: now)

        recovered_count += 1
        Rails.logger.error(
          "Stale attachment scan recovered scan_id=#{scan.id} " \
          "blob_id=#{scan.active_storage_blob_id} status_code=SCAN_TIMEOUT"
        )
      end

      return if recovered_count.zero?

      raise TerminalRecoveryError, "stale attachment scans failed with SCAN_TIMEOUT"
    end

    private

    def stale_pending_scans(now:)
      cutoff = now - AttachmentScanJob::POLL_WINDOW
      AttachmentScan.where(status: "pending", created_at: ...cutoff)
    end
  end
end
