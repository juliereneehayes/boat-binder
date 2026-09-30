require "openssl"

class User < ApplicationRecord
  ROLES = %w[admin captain owner].freeze
  INVITATION_EXPIRES_IN = 7.days
  EMAIL_VERIFICATION_EXPIRES_IN = 24.hours
  EMAIL_CHANGE_EXPIRES_IN = 24.hours
  PASSWORD_RESET_EXPIRES_IN = 15.minutes
  PASSWORD_MINIMUM_LENGTH = 15
  PASSWORD_MAXIMUM_BYTES = 72
  COMPROMISED_PASSWORD_MESSAGE = "has appeared in known data breaches. Choose a different password."

  class_attribute :password_compromise_checker, default: ->(password) { CompromisedPasswordChecker.call(password) }
  attr_writer :password_compromise_checker

  has_secure_password validations: false, reset_token: { expires_in: PASSWORD_RESET_EXPIRES_IN }
  generates_token_for :invitation, expires_in: INVITATION_EXPIRES_IN do
    [ invitation_sent_at&.to_f, invitation_accepted_at&.to_f, active? ]
  end
  generates_token_for :email_verification, expires_in: EMAIL_VERIFICATION_EXPIRES_IN do
    [ email_verification_sent_at&.to_f, email_verified_at&.to_f, active? ]
  end
  generates_token_for :email_change, expires_in: EMAIL_CHANGE_EXPIRES_IN do
    state = [ email_address, pending_email_address, email_change_requested_at&.to_f, active? ].to_json
    key = Rails.application.key_generator.generate_key("email-change-token-state", 32)
    OpenSSL::HMAC.hexdigest("SHA256", key, state)
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
  normalizes :email_address, :pending_email_address, with: ->(value) { value.strip.downcase }

  validates :email_address, presence: true, uniqueness: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :pending_email_address, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_nil: true
  validates :role, inclusion: { in: ROLES }
  validates :name, length: { maximum: 120 }
  validates :password, confirmation: true, length: { minimum: PASSWORD_MINIMUM_LENGTH }, allow_nil: true
  validates :password_confirmation, presence: true, if: -> { password.present? }
  validate :password_fits_bcrypt_byte_limit
  validate :password_digest_required_unless_pending_invitation
  validate :password_has_not_been_compromised
  validate :email_verification_lifecycle_is_consistent
  validate :email_change_lifecycle_is_consistent
  validate :pending_email_address_is_available, if: :will_save_change_to_pending_email_address?
  validate :owner_user_limits_allow_role_change

  def email
    email_address
  end

  def password=(unencrypted_password)
    remove_instance_variable(:@password_compromise_check_result) if defined?(@password_compromise_check_result)
    super
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

  def email_change_pending?
    pending_email_address.present? && email_change_requested_at.present? &&
      email_change_requested_at > EMAIL_CHANGE_EXPIRES_IN.ago
  end

  def active_sessions
    sessions.includes(:user).order(created_at: :desc).select(&:valid_at?)
  end

  private

  def password_fits_bcrypt_byte_limit
    return if password.nil? || password.bytesize <= PASSWORD_MAXIMUM_BYTES

    errors.add(:password, "is too long. Please use a shorter password.")
  end

  def password_has_not_been_compromised
    return unless password.present?
    return unless will_save_change_to_password_digest?
    return if errors[:password].any? || errors[:password_confirmation].any?
    # A few workflows validate before saving. Reuse only the boolean result for
    # this assignment; password= clears it before any later assignment.
    compromised = if defined?(@password_compromise_check_result)
      @password_compromise_check_result
    else
      @password_compromise_check_result = password_compromise_checker.call(password)
    end
    return unless compromised

    errors.add(:password, COMPROMISED_PASSWORD_MESSAGE)
  end

  def password_compromise_checker
    @password_compromise_checker || self.class.password_compromise_checker
  end

  def password_digest_required_unless_pending_invitation
    return if password_digest.present?
    return if invitation_pending?

    errors.add(:password, "can't be blank")
  end

  def email_verification_lifecycle_is_consistent
    return if email_verified_at.blank? || email_verification_sent_at.present?

    errors.add(:email_verified_at, "requires a verification email timestamp")
  end

  def email_change_lifecycle_is_consistent
    if pending_email_address.present? && email_change_requested_at.blank?
      errors.add(:email_change_requested_at, "is required for a pending email change")
    elsif pending_email_address.blank? && email_change_requested_at.present?
      errors.add(:pending_email_address, "can't be blank")
    end
  end

  def pending_email_address_is_available
    return if pending_email_address.blank?

    if pending_email_address == email_address ||
        User.where(email_address: pending_email_address).where.not(id:).exists?
      errors.add(:pending_email_address, :taken)
    end
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
