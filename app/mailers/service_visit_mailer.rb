class ServiceVisitMailer < ApplicationMailer
  helper ApplicationHelper

  def summary(service_visit, recipient_email)
    @service_visit = service_visit
    @vessel = service_visit.asset
    @account = @vessel.account
    if service_visit.summary_recipient_can_access_report?(recipient_email)
      @report_url = report_vessel_service_visit_url(@vessel, @service_visit)
    end

    mail(
      subject: "#{@vessel.name} service visit report - #{@service_visit.visit_date.to_fs(:long)}",
      to: recipient_email
    )
  end
end
