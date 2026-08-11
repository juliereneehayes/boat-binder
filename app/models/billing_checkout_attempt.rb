class BillingCheckoutAttempt < ApplicationRecord
  ACTIVE_STATUSES = %w[creating open submitted].freeze
  STATUSES = (ACTIVE_STATUSES + %w[completed canceled expired replaced]).freeze

  belongs_to :account

  validates :option_key, :stripe_customer_id, :idempotency_key, presence: true
  validates :idempotency_key, uniqueness: true
  validates :stripe_checkout_session_id, uniqueness: true, allow_nil: true
  validates :status, inclusion: { in: STATUSES }
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
end
