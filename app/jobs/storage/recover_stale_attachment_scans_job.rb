module Storage
  class RecoverStaleAttachmentScansJob < ApplicationJob
    queue_as :background

    TerminalRecoveryError = Class.new(StandardError)

    def perform(now: Time.current)
      terminal_failure = false

      stale_pending_scans(now:).find_each do |scan|
        AttachmentScanJob.perform_now(scan.id, now:)
      rescue AttachmentScanJob::TerminalScanError
        terminal_failure = true
      end

      return unless terminal_failure

      raise TerminalRecoveryError, "stale attachment scan reconciliation failed"
    end

    private

    def stale_pending_scans(now:)
      cutoff = now - AttachmentScanJob::POLL_WINDOW
      AttachmentScan.where(status: "pending", created_at: ...cutoff)
    end
  end
end
