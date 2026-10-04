module NoStoreResponse
  extend ActiveSupport::Concern

  included do
    after_action :set_no_store_response_header
  end

  private

  def set_no_store_response_header
    response.headers["Cache-Control"] = "no-store"
  end
end
