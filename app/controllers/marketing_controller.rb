class MarketingController < ApplicationController
  allow_unauthenticated_access
  layout "marketing"

  def show
    @google_analytics_measurement_id = PublicAnalytics::Configuration.measurement_id(host: request.host)
  end
end
