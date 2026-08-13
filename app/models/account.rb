class Account < ApplicationRecord
  ACCOUNT_TYPES = %w[internal client].freeze
  DEFAULT_TIME_ZONE = "America/Los_Angeles"
  VALID_TIME_ZONES = ActiveSupport::TimeZone.all.map { |zone| zone.tzinfo.name }.uniq.freeze

  has_many :account_memberships, dependent: :destroy
  has_many :users, through: :account_memberships
  has_many :contacts, dependent: :destroy
  has_many :assets, dependent: :destroy
  has_many :vessel_assets, -> { where(asset_type: "vessel", active: true).order(:name) }, class_name: "Asset"
  has_many :documents, dependent: :destroy
  has_many :binder_notes, dependent: :destroy
  has_many :billing_checkout_attempts, dependent: :destroy
  has_one :subscription, dependent: :destroy

  before_validation :set_default_time_zone

  validates :name, presence: true
  validates :account_type, inclusion: { in: ACCOUNT_TYPES }
  validates :time_zone, inclusion: { in: VALID_TIME_ZONES }

  scope :active, -> { where(active: true) }
  scope :inactive, -> { where(active: false) }
  scope :client, -> { where(account_type: "client") }
  scope :ordered, -> { order(:name) }

  def primary_contact
    contacts.find { |contact| contact.role.to_s.downcase.include?("owner") } || contacts.first
  end

  def owner_user_memberships
    account_memberships
      .joins(:user)
      .includes(:user)
      .where(users: { role: "owner" })
      .order(:id)
  end

  def transactional_owner_recipient
    User.joins(:account_memberships)
      .where(account_memberships: { account_id: id, active: true })
      .where(role: "owner", active: true)
      .where.not(email_address: [ nil, "" ])
      .order(AccountMembership.arel_table[:id].asc)
      .first
  end

  def transactional_recipient_email
    transactional_owner_recipient&.email_address.presence || primary_contact&.email.presence
  end

  def status_label
    active? ? "Active" : "Inactive"
  end

  def status_tone
    active? ? :success : :neutral
  end

  private

  def set_default_time_zone
    self.time_zone = DEFAULT_TIME_ZONE if time_zone.blank?
  end
end
