class BillingCheckoutAttempt < ApplicationRecord
  ACTIVE_STATUSES = %w[creating open replacing submitted].freeze
  STATUSES = (ACTIVE_STATUSES + %w[completed canceled expired replaced]).freeze
  ALLOWED_TRANSITIONS = {
    "creating" => %w[open completed canceled],
    "open" => %w[replacing submitted completed canceled expired],
    "replacing" => %w[submitted completed replaced],
    "submitted" => %w[completed],
    "completed" => [],
    "canceled" => [],
    "expired" => [],
    "replaced" => []
  }.freeze

  belongs_to :account

  validates :option_key, :stripe_customer_id, :idempotency_key, presence: true
  validates :idempotency_key, uniqueness: true
  validates :stripe_checkout_session_id, uniqueness: true, allow_nil: true
  validates :status, inclusion: { in: STATUSES }
  validate :status_transition_is_allowed, if: :will_save_change_to_status?
  validates :account_id,
    uniqueness: {
      conditions: -> { where(status: ACTIVE_STATUSES) },
      message: "already has an active Checkout attempt"
    },
    if: :active?

  scope :active, -> { where(status: ACTIVE_STATUSES) }
  scope :recent_first, -> { order(created_at: :desc, id: :desc) }

  def active?
    ACTIVE_STATUSES.include?(status)
  end

  private

  def status_transition_is_allowed
    return unless persisted?

    previous_status = status_in_database
    return if previous_status.blank? || ALLOWED_TRANSITIONS.fetch(previous_status, []).include?(status)

    errors.add(:status, "cannot transition from #{previous_status} to #{status}")
  end
end
