class SelfServiceRegistration
  include ActiveModel::Model

  GENERIC_FAILURE_MESSAGE = "Registration could not be completed. Please try again."

  attr_accessor :name, :email_address, :password, :password_confirmation
  attr_reader :account, :membership, :subscription, :user

  validates :name, presence: true, length: { maximum: 120 }
  validates :email_address, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :password, presence: true, confirmation: true, length: { maximum: 72 }

  def name=(value)
    @name = value.to_s.squish.presence
  end

  def email_address=(value)
    @email_address = value.to_s.strip.downcase
  end

  def initialize(attributes = {})
    super
    build_record_graph
  end

  def call
    return self unless valid?

    persist_record_graph!
    @created = true
    deliver_verification_email
    self
  rescue ActiveRecord::RecordInvalid => error
    duplicate_email?(error.record) ? accept_duplicate : record_failure
  rescue ActiveRecord::RecordNotUnique
    accept_duplicate
  end

  def accepted?
    created? || duplicate?
  end

  def created?
    @created == true
  end

  def duplicate?
    @duplicate == true
  end

  def delivery_failed?
    @delivery_failed == true
  end

  private

  def build_record_graph
    @user = User.new(
      name:,
      email_address:,
      password:,
      password_confirmation:,
      role: "owner",
      active: false,
      email_verification_sent_at: nil,
      email_verified_at: nil
    )
    @account = Account.new(
      name:,
      account_type: "client",
      active: true,
      time_zone: Account::DEFAULT_TIME_ZONE
    )
    @subscription = account.build_subscription(Subscription.pending_checkout_attributes)
    @membership = AccountMembership.new(
      user:,
      account:,
      access_level: "editor",
      active: true
    )
  end

  def persist_record_graph!
    ActiveRecord::Base.transaction do
      user.email_verification_sent_at = Time.current
      user.save!
      account.save!
      subscription.save!
      membership.save!
    end
  end

  def deliver_verification_email
    EmailVerificationsMailer.verify(user).deliver_now
  rescue *ApplicationMailer::DELIVERY_ERRORS => error
    @delivery_failed = true
    Rails.logger.error(
      "Registration verification email delivery failed for " \
      "user_id=#{user.id} account_id=#{account.id}: #{error.class}: #{error.message}"
    )
  end

  def duplicate_email?(record)
    record.equal?(user) && record.errors.of_kind?(:email_address, :taken)
  end

  def accept_duplicate
    @duplicate = true
    errors.clear
    self
  end

  def record_failure
    errors.add(:base, GENERIC_FAILURE_MESSAGE)
    self
  end
end
