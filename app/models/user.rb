require "openssl"
require "rotp"
require "securerandom"

class User < ApplicationRecord
  ROLES = %w[admin captain owner].freeze
  INVITATION_EXPIRES_IN = 7.days
  EMAIL_VERIFICATION_EXPIRES_IN = 24.hours
  EMAIL_CHANGE_EXPIRES_IN = 24.hours
  PASSWORD_RESET_EXPIRES_IN = 15.minutes
  PASSWORD_MINIMUM_LENGTH = 15
  PASSWORD_MAXIMUM_BYTES = 72
  MFA_TOTP_PERIOD = 30
  MFA_TOTP_DIGITS = 6
  MFA_TOTP_DRIFT = 1
  MFA_RECOVERY_CODE_COUNT = 10
  MFA_RECOVERY_CODE_BYTES = 16
  COMPROMISED_PASSWORD_MESSAGE = "has appeared in known data breaches. Choose a different password."

  class_attribute :password_compromise_checker, default: ->(password) { CompromisedPasswordChecker.call(password) }
  attr_writer :password_compromise_checker

  has_secure_password validations: false, reset_token: { expires_in: PASSWORD_RESET_EXPIRES_IN }
  encrypts :mfa_totp_secret
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
  validate :mfa_state_is_consistent

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

  def mfa_enrolled?
    mfa_enrolled_at.present?
  end

  def mfa_enrollment_pending?
    !mfa_enrolled? && mfa_totp_secret.present?
  end

  def begin_mfa_enrollment!
    with_lock do
      update!(
        mfa_totp_secret: ROTP::Base32.random_base32(32),
        mfa_enrolled_at: nil,
        mfa_last_accepted_timestep: nil,
        mfa_recovery_code_digests: []
      )
    end
  end

  def mfa_enrollment_secret
    mfa_totp_secret if mfa_enrollment_pending?
  end

  def mfa_enrollment_provisioning_uri
    return unless mfa_enrollment_pending?

    mfa_totp.provisioning_uri(email_address)
  end

  def confirm_mfa_enrollment!(code, at: Time.current)
    with_lock do
      reload
      next unless mfa_enrollment_pending?

      accepted_timestep = verify_mfa_totp(code, at:)
      next unless accepted_timestep

      recovery_codes = self.class.generate_mfa_recovery_codes
      update!(
        mfa_enrolled_at: at,
        mfa_last_accepted_timestep: accepted_timestep,
        mfa_recovery_code_digests: recovery_codes.map { |recovery_code| mfa_recovery_digest(recovery_code) }
      )
      recovery_codes
    end
  end

  def accept_mfa_totp!(code, at: Time.current)
    with_lock do
      reload
      next false unless mfa_enrolled?

      accepted_timestep = verify_mfa_totp(code, at:)
      next false unless accepted_timestep

      update!(mfa_last_accepted_timestep: accepted_timestep)
      true
    end
  end

  def consume_mfa_recovery_code!(code)
    candidate = self.class.normalize_mfa_recovery_code(code)
    return false unless /\A[0-9A-F]{32}\z/.match?(candidate)

    with_lock do
      reload
      next false unless mfa_enrolled?

      matching_index = nil
      mfa_recovery_code_digests.each_with_index do |digest, index|
        matching_index ||= index if BCrypt::Password.new(digest).is_password?(candidate)
      end
      next false unless matching_index

      remaining_digests = mfa_recovery_code_digests.dup
      remaining_digests.delete_at(matching_index)
      update!(mfa_recovery_code_digests: remaining_digests)
      true
    end
  rescue BCrypt::Errors::InvalidHash
    false
  end

  def regenerate_mfa_recovery_codes!
    with_lock do
      reload
      raise ActiveRecord::RecordInvalid, self unless mfa_enrolled?

      recovery_codes = self.class.generate_mfa_recovery_codes
      update!(
        mfa_recovery_code_digests: recovery_codes.map { |recovery_code| mfa_recovery_digest(recovery_code) }
      )
      recovery_codes
    end
  end

  def reset_mfa_for_reenrollment!
    begin_mfa_enrollment!
  end

  def cancel_pending_mfa_enrollment!
    with_lock do
      reload
      next false unless owner? && mfa_enrollment_pending? && !mfa_enrolled?

      update!(
        mfa_totp_secret: nil,
        mfa_enrolled_at: nil,
        mfa_last_accepted_timestep: nil,
        mfa_recovery_code_digests: []
      )
      true
    end
  end

  def mfa_recovery_codes_remaining
    mfa_recovery_code_digests.length
  end

  class << self
    def normalize_mfa_totp(code)
      code.to_s.gsub(/[\s-]/, "")
    end

    def normalize_mfa_recovery_code(code)
      code.to_s.gsub(/[\s-]/, "").upcase
    end

    def generate_mfa_recovery_codes
      Array.new(MFA_RECOVERY_CODE_COUNT) do
        SecureRandom.hex(MFA_RECOVERY_CODE_BYTES).upcase.scan(/.{4}/).join("-")
      end
    end
  end

  private

  def mfa_totp
    ROTP::TOTP.new(
      mfa_totp_secret,
      issuer: "Boat Binder",
      digits: MFA_TOTP_DIGITS,
      interval: MFA_TOTP_PERIOD
    )
  end

  def verify_mfa_totp(code, at:)
    normalized_code = self.class.normalize_mfa_totp(code)
    return unless /\A\d{#{MFA_TOTP_DIGITS}}\z/.match?(normalized_code)

    accepted_at = mfa_totp.verify(
      normalized_code,
      at: at.to_i,
      drift_behind: MFA_TOTP_DRIFT * MFA_TOTP_PERIOD,
      drift_ahead: MFA_TOTP_DRIFT * MFA_TOTP_PERIOD,
      after: mfa_last_accepted_timestep && mfa_last_accepted_timestep * MFA_TOTP_PERIOD
    )
    accepted_at && accepted_at / MFA_TOTP_PERIOD
  end

  def mfa_recovery_digest(code)
    BCrypt::Password.create(self.class.normalize_mfa_recovery_code(code))
  end

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

  def mfa_state_is_consistent
    if mfa_enrolled? && mfa_totp_secret.blank?
      errors.add(:mfa_totp_secret, "is required for MFA enrollment")
    end
    if mfa_last_accepted_timestep.present? && !mfa_enrolled?
      errors.add(:mfa_last_accepted_timestep, "requires MFA enrollment")
    end
    if mfa_recovery_code_digests.any? && !mfa_enrolled?
      errors.add(:mfa_recovery_code_digests, "require MFA enrollment")
    end
  end
end
