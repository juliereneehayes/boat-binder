class ErrorsController < ApplicationController
  allow_unauthenticated_access

  def not_found
    @not_found_message = NotFoundMessage.pick(seed: request.request_id)

    render :not_found, status: :not_found
  end

  def unprocessable_entity
    render file: Rails.public_path.join("422.html"), layout: false, status: :unprocessable_entity
  end

  def internal_server_error
    render file: Rails.public_path.join("500.html"), layout: false, status: :internal_server_error
  end
end
