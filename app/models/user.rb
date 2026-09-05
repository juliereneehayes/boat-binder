class User < ApplicationRecord
  ROLES = %w[admin captain owner].freeze
  INVITATION_EXPIRES_IN = 7.days
  EMAIL_VERIFICATION_EXPIRES_IN = 24.hours
  PASSWORD_RESET_EXPIRES_IN = 15.minutes

  has_secure_password validations: false, reset_token: { expires_in: PASSWORD_RESET_EXPIRES_IN }
  generates_token_for :invitation, expires_in: INVITATION_EXPIRES_IN do
    [ invitation_sent_at&.to_f, invitation_accepted_at&.to_f, active? ]
  end
  generates_token_for :email_verification, expires_in: EMAIL_VERIFICATION_EXPIRES_IN do
    [ email_verification_sent_at&.to_f, email_verified_at&.to_f, active? ]
  end

  has_many :sessions, dependent: :destroy
  has_many :account_memberships, dependent: :destroy
  has_many :accounts, through: :account_memberships
  has_many :account_export_requests, foreign_key: :requester_id, dependent: :restrict_with_exception
  has_many :service_visits, foreign_key: :performed_by_user_id, inverse_of: :performed_by_user, dependent: :restrict_with_exception
  has_many :completed_service_visit_follow_ups, foreign_key: :follow_up_completed_by_user_id,
    class_name: "ServiceVisit", dependent: :restrict_with_exception
  has_many :service_visit_follow_up_events, foreign_key: :actor_user_id,
    dependent: :restrict_with_exception

  normalizes :name, with: ->(value) { value.squish.presence }
  normalizes :email_address, with: ->(e) { e.strip.downcase }

  validates :email_address, presence: true, uniqueness: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :role, inclusion: { in: ROLES }
  validates :name, length: { maximum: 120 }
  validates :password, presence: true, confirmation: true, length: { maximum: 72 }, allow_nil: true
  validate :password_digest_required_unless_pending_invitation
  validate :email_verification_lifecycle_is_consistent
  validate :owner_user_limits_allow_role_change

  def email
    email_address
  end

  def admin?
    role == "admin"
  end

  def captain?
    role == "captain"
  end

  def owner?
    role == "owner"
  end

  def internal?
    admin? || captain?
  end

  def active_account_ids
    return Account.select(:id) if internal?

    account_memberships.active.select(:account_id)
  end

  def invitation_pending?
    invitation_sent_at.present? && invitation_accepted_at.blank? && !active?
  end

  def invitation_accepted?
    invitation_accepted_at.present?
  end

  def email_verification_pending?
    email_verification_sent_at.present? && email_verified_at.blank? && !active?
  end

  private

  def password_digest_required_unless_pending_invitation
    return if password_digest.present?
    return if invitation_pending?

    errors.add(:password, "can't be blank")
  end

  def email_verification_lifecycle_is_consistent
    return if email_verified_at.blank? || email_verification_sent_at.present?

    errors.add(:email_verified_at, "requires a verification email timestamp")
  end

  def owner_user_limits_allow_role_change
    return unless owner? && will_save_change_to_role? && persisted?

    account_ids = account_memberships.active.order(:account_id).pluck(:account_id)
    return if account_ids.empty?

    # Active Record's save transaction covers validation and persistence. These
    # locks therefore remain held through the role UPDATE; stable ordering avoids
    # deadlocks when a user belongs to more than one Account.
    Account.transaction do
      Account.where(id: account_ids).order(:id).lock.includes(:subscription).each do |account|
        next if Billing::OwnerUserLimit.allows_owner?(account:, user_id: id)

        errors.add(:role, Billing::OwnerUserLimit::ERROR_MESSAGE)
        break
      end
    end
  end
end
