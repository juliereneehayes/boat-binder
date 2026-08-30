class AccountExportRequest < ApplicationRecord
  STATUSES = %w[requested approved declined fulfilled].freeze
  OPEN_STATUSES = %w[requested approved].freeze
  LIFECYCLE_CONTEXTS = %w[
    scheduled_cancellation
    payment_recovery_pending
    read_only_grace
    retained_inactive
    archive_eligible
  ].freeze

  belongs_to :account
  belongs_to :requester, class_name: "User"
  belongs_to :recipient_verified_by, class_name: "User", optional: true
  belongs_to :scope_verified_by, class_name: "User", optional: true
  belongs_to :decided_by, class_name: "User", optional: true
  belongs_to :fulfilled_by, class_name: "User", optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :lifecycle_context, inclusion: { in: LIFECYCLE_CONTEXTS }
  validates :account_id, uniqueness: {
    conditions: -> { where(status: OPEN_STATUSES) },
    message: "already has an open export request"
  }, if: :open?
  validates :recipient_verified_by, presence: true, if: :recipient_verified_at?
  validates :scope_verified_by, presence: true, if: :scope_verified_at?
  validates :decided_at, :decided_by, presence: true, if: :decided?
  validates :fulfilled_at, :fulfilled_by, presence: true, if: :fulfilled?
  validate :verification_required_for_approved_request

  scope :recent_first, -> { order(created_at: :desc, id: :desc) }
  scope :open, -> { where(status: OPEN_STATUSES) }

  def open?
    status.in?(OPEN_STATUSES)
  end

  def requested?
    status == "requested"
  end

  def approved?
    status == "approved"
  end

  def declined?
    status == "declined"
  end

  def decided?
    status.in?(%w[approved declined fulfilled])
  end

  def fulfilled?
    status == "fulfilled"
  end

  def verify_recipient!(reviewer:)
    review_open_request! do
      self.recipient_verified_at ||= Time.current
      self.recipient_verified_by ||= reviewer
    end
  end

  def verify_scope!(reviewer:)
    review_open_request! do
      self.scope_verified_at ||= Time.current
      self.scope_verified_by ||= reviewer
    end
  end

  def approve!(reviewer:)
    review_requested_request! do
      unless recipient_verified_at? && scope_verified_at?
        errors.add(:base, "Recipient and data scope must be verified before approval.")
        raise ActiveRecord::RecordInvalid, self
      end

      self.status = "approved"
      self.decided_at = Time.current
      self.decided_by = reviewer
    end
  end

  def decline!(reviewer:)
    review_requested_request! do
      self.status = "declined"
      self.decided_at = Time.current
      self.decided_by = reviewer
    end
  end

  def fulfill!(reviewer:)
    with_lock do
      unless status == "approved"
        errors.add(:base, "Only an approved export request can be fulfilled.")
        raise ActiveRecord::RecordInvalid, self
      end

      update!(status: "fulfilled", fulfilled_at: Time.current, fulfilled_by: reviewer)
    end
  end

  private

  def verification_required_for_approved_request
    return unless status.in?(%w[approved fulfilled])
    return if recipient_verified_at? && scope_verified_at?

    errors.add(:base, "Recipient and data scope must be verified before approval.")
  end

  def review_open_request!
    with_lock do
      unless open?
        errors.add(:base, "This export request is already closed.")
        raise ActiveRecord::RecordInvalid, self
      end

      yield
      save!
    end
  end

  def review_requested_request!(&block)
    with_lock do
      unless status == "requested"
        errors.add(:base, "This export request has already been decided.")
        raise ActiveRecord::RecordInvalid, self
      end

      block.call
      save!
    end
  end
end
