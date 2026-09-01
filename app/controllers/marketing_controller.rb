class MarketingController < ApplicationController
  allow_unauthenticated_access
  skip_before_action :ensure_active_user!
  layout "marketing"

  def show
  end
end
