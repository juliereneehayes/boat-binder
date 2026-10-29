class ManagedServiceRelationship < ApplicationRecord
  belongs_to :account

  validates :account_id, uniqueness: true

  scope :effective, -> { where(active: true).joins(:account).merge(Account.active) }

  def self.effective_for?(account)
    account.present? && effective.exists?(account_id: account.id)
  end
end
