module Billing
  class TrialStartConfirmationDeliveryJob < ApplicationJob
    queue_as :default

    def perform(confirmation_id)
      confirmation = BillingTrialStartConfirmation.find(confirmation_id)
      return unless confirmation.claim_delivery!(job_id: job_id)

      recipient = confirmation.account.verified_transactional_owner_recipient
      unless recipient
        confirmation.mark_skipped!(error_code: "eligible_recipient_unavailable")
        Rails.logger.info(
          "Trial start confirmation result=skipped " \
          "confirmation_id=#{confirmation.id} reason=eligible_recipient_unavailable"
        )
        return
      end

      ActionMailer::Base.logger.silence(Logger::FATAL) do
        TrialStartConfirmationMailer.confirmation(confirmation, recipient.email_address).deliver_now
      end
      confirmation.mark_delivered!
      Rails.logger.info(
        "Trial start confirmation result=delivered confirmation_id=#{confirmation.id}"
      )
    rescue StandardError => error
      confirmation&.mark_failed!(error_code: "delivery_failed")
      Rails.logger.error(
        "Trial start confirmation delivery failed " \
        "confirmation_id=#{confirmation&.id} exception_class=#{error.class.name}"
      )
      raise
    end
  end
end
