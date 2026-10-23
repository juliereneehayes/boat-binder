class AttachmentScan < ApplicationRecord
  STATUSES = %w[pending clean rejected failed trusted_existing].freeze
  AVAILABLE_STATUSES = %w[clean trusted_existing].freeze
  TERMINAL_STATUSES = %w[clean rejected failed trusted_existing].freeze
  PROVIDER = "guardduty"
  STATUS_CODES = %w[
    NO_THREATS_FOUND
    THREATS_FOUND
    UNSUPPORTED
    ACCESS_DENIED
    FAILED
    UNKNOWN
    SCAN_TIMEOUT
    PROVIDER_ERROR
    UNSUPPORTED_SERVICE
    ENQUEUE_FAILED
    ROLLOUT_BACKFILL
  ].freeze

  belongs_to :active_storage_blob, class_name: "ActiveStorage::Blob"

  validates :status, inclusion: { in: STATUSES }
  validates :provider, inclusion: { in: [ PROVIDER ] }
  validates :check_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :status_code, inclusion: { in: STATUS_CODES }, allow_nil: true

  after_create_commit :enqueue_pending_scan

  scope :available, -> { where(status: AVAILABLE_STATUSES) }

  class << self
    def register_pending!(blob)
      create_or_find_by!(active_storage_blob: blob) do |scan|
        scan.status = "pending"
        scan.provider = PROVIDER
      end
    end

    def available_blob?(blob)
      available.exists?(active_storage_blob_id: blob.id)
    end
  end

  def available?
    status.in?(AVAILABLE_STATUSES)
  end

  def terminal?
    status.in?(TERMINAL_STATUSES)
  end

  def record_check!(checked_at: Time.current)
    with_lock do
      return false unless status == "pending"

      update!(check_count: check_count + 1, last_checked_at: checked_at)
      true
    end
  end

  def mark_clean!(completed_at: Time.current)
    transition_pending!(status: "clean", status_code: "NO_THREATS_FOUND", completed_at:)
  end

  def mark_rejected!(completed_at: Time.current)
    transaction do
      with_lock do
        return false unless status == "pending"

        update!(status: "rejected", status_code: "THREATS_FOUND", completed_at:)
        SecurityAudit::Recorder.record!(
          action: "attachment.malware_rejected",
          outcome: "denied",
          target: self
        )
        true
      end
    end
  end

  def mark_failed!(status_code:, completed_at: Time.current)
    transition_pending!(status: "failed", status_code:, completed_at:)
  end

  private

  def transition_pending!(status:, status_code:, completed_at:)
    with_lock do
      return false unless self.status == "pending"

      update!(status:, status_code:, completed_at:)
      true
    end
  end

  def enqueue_pending_scan
    return unless status == "pending"

    Storage::AttachmentScanJob.perform_later(id)
  rescue StandardError => error
    mark_failed!(status_code: "ENQUEUE_FAILED")
    Rails.logger.error(
      "Attachment scan enqueue failed scan_id=#{id} " \
      "blob_id=#{active_storage_blob_id} exception_class=#{error.class.name}"
    )
  end
end
