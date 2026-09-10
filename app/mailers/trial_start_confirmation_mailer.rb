class TrialStartConfirmationMailer < ApplicationMailer
  helper ApplicationHelper

  def confirmation(confirmation, recipient_email)
    @confirmation = confirmation
    @account = confirmation.account
    @option = Billing::SubscriptionPlanCatalog.fetch(confirmation.option_key)
    @billing_interval = @option.interval == "month" ? "Monthly" : "Annual"
    @manage_billing_url = root_url

    mail(
      subject: "Your Boat Binder Self Managed trial has started",
      to: recipient_email
    )
  end
end
