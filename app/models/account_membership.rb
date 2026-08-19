class AccountMembership < ApplicationRecord
  ACCESS_LEVELS = %w[read_only editor].freeze
  DEFAULT_ACCESS_LEVEL = "read_only"

  belongs_to :user
  belongs_to :account

  validates :access_level, inclusion: { in: ACCESS_LEVELS }
  validates :account_id, uniqueness: { scope: :user_id }

  scope :active, -> { where(active: true) }
  scope :ordered, -> { joins(:account).order("accounts.name") }

  def status_label
    active? ? "Active" : "Inactive"
  end

  def transactional_email_eligible?
    active? && user.owner? && user.active? && user.email_address.present?
  end
end
