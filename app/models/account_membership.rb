class AccountMembership < ApplicationRecord
  ACCESS_LEVELS = %w[read_only editor].freeze
  DEFAULT_ACCESS_LEVEL = "read_only"

  belongs_to :user
  belongs_to :account

  validates :access_level, inclusion: { in: ACCESS_LEVELS }
  validates :account_id, uniqueness: { scope: :user_id }
  validate :within_owner_user_limit

  scope :active, -> { where(active: true) }
  scope :ordered, -> { joins(:account).order("accounts.name") }

  def status_label
    active? ? "Active" : "Inactive"
  end

  def transactional_email_eligible?
    active? && user.owner? && user.active? && user.email_address.present?
  end

  private

  def within_owner_user_limit
    return unless active? && user&.owner? && account_id.present?

    # Active Record wraps validations and persistence in the same save transaction.
    # This nested transaction joins it, so the Account lock remains held through
    # the membership INSERT or UPDATE.
    Account.transaction do
      locked_account = Account.lock.includes(:subscription).find(account_id)
      return if Billing::OwnerUserLimit.allows_owner?(
        account: locked_account,
        user_id: user_id || user.id
      )

      errors.add(:base, Billing::OwnerUserLimit::ERROR_MESSAGE)
    end
  end
end
