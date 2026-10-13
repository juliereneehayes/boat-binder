class PasswordResetDeliveryJob < ApplicationJob
  queue_as :default

  def perform(user_id)
    user = User.find_by(id: user_id)
    return unless user

    PasswordsMailer.reset(user).deliver_now
    Rails.logger.info("Password reset email delivered for user_id=#{user.id}")
  rescue *ApplicationMailer::DELIVERY_ERRORS => error
    Rails.logger.error(
      "Password reset email delivery failed for user_id=#{user_id} " \
      "exception_class=#{error.class.name}"
    )
    false
  end
end
