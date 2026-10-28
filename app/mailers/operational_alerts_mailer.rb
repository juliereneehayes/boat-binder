class OperationalAlertsMailer < ApplicationMailer
  def health_alert(conditions:, detected_at:, recipient:)
    @conditions = conditions
    @detected_at = detected_at.utc.iso8601

    mail(
      subject: "Boat Binder operational health alert",
      to: recipient
    )
  end
end
