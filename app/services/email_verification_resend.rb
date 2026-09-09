class EmailVerificationResend
  TOKEN_ROTATION_INCREMENT = Rational(1, 1_000_000)
  Rotation = Data.define(:previous_sent_at, :rotated_sent_at)

  attr_reader :user

  def initialize(email_address)
    @email_address = email_address.to_s.strip.downcase
  end

  def call
    @user = User.find_by(email_address:)
    rotation = rotate_pending_verification
    return self unless rotation

    SelfServiceRegistration.deliver_email(EmailVerificationsMailer.verify(user))
    self
  rescue *ApplicationMailer::DELIVERY_ERRORS => error
    restore_previous_verification(rotation) if rotation
    Rails.logger.error(
      "Verification resend email delivery failed for " \
      "user_id=#{user&.id} exception_class=#{error.class}"
    )
    self
  end

  private

  attr_reader :email_address

  def rotate_pending_verification
    return unless user

    user.with_lock do
      user.account_memberships.reset
      next unless SelfServiceRegistration.pending_verification?(user)

      previous_sent_at = user.email_verification_sent_at
      rotated_sent_at = [ Time.current, previous_sent_at + TOKEN_ROTATION_INCREMENT ].max
      user.update!(email_verification_sent_at: rotated_sent_at)

      Rotation.new(previous_sent_at:, rotated_sent_at: user.reload.email_verification_sent_at)
    end
  end

  def restore_previous_verification(rotation)
    user.with_lock do
      user.reload
      next unless user.email_verification_sent_at == rotation.rotated_sent_at
      next unless user.email_verified_at.blank? && !user.active?

      user.update!(email_verification_sent_at: rotation.previous_sent_at)
    end
  end
end
