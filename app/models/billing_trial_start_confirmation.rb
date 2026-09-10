class BillingTrialStartConfirmation < ApplicationRecord
  STATUSES = %w[pending enqueued delivering delivered skipped failed].freeze
  OPTION_KEYS = [
    Billing::SubscriptionPlanCatalog::SELF_MANAGED_MONTHLY_KEY,
    Billing::SubscriptionPlanCatalog::SELF_MANAGED_ANNUAL_KEY
  ].freeze

  belongs_to :account
  belongs_to :subscription

  validates :external_subscription_id, presence: true
  validates :option_key, inclusion: { in: OPTION_KEYS }
  validates :trial_started_at, :trial_ends_at, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :trial_started_at,
    uniqueness: { scope: %i[account_id external_subscription_id] }
  validate :trial_end_follows_start

  after_create_commit :enqueue_delivery

  def claim_delivery!(job_id:)
    with_lock do
      return false if delivered? || skipped?
      return false if delivering? && active_job_id != job_id

      update!(status: "delivering", active_job_id: job_id, error_code: nil, failed_at: nil)
      true
    end
  end

  def mark_delivered!
    update!(status: "delivered", delivered_at: Time.current, failed_at: nil, error_code: nil)
  end

  def mark_skipped!(error_code:)
    update!(status: "skipped", skipped_at: Time.current, failed_at: nil, error_code:)
  end

  def mark_failed!(error_code:)
    update!(status: "failed", failed_at: Time.current, error_code:)
  end

  def delivered?
    status == "delivered"
  end

  def skipped?
    status == "skipped"
  end

  def delivering?
    status == "delivering"
  end

  private

  def enqueue_delivery
    job = Billing::TrialStartConfirmationDeliveryJob.perform_later(id)
    unless job.successfully_enqueued?
      raise(job.enqueue_error || ActiveJob::EnqueueError.new("trial confirmation could not be enqueued"))
    end

    now = Time.current
    self.class.where(id:, status: "pending").update_all(
      status: "enqueued",
      active_job_id: job.job_id,
      enqueued_at: now,
      updated_at: now
    )
  rescue ActiveJob::EnqueueError, SolidQueue::Job::EnqueueError => error
    now = Time.current
    self.class.where(id:, status: %w[pending enqueued]).update_all(
      status: "failed",
      failed_at: now,
      error_code: "enqueue_failed",
      updated_at: now
    )
    Rails.logger.error(
      "Trial start confirmation enqueue failed " \
      "confirmation_id=#{id} exception_class=#{error.class.name}"
    )
  end

  def trial_end_follows_start
    return if trial_started_at.blank? || trial_ends_at.blank? || trial_ends_at > trial_started_at

    errors.add(:trial_ends_at, "must be after the trial start")
  end
end
