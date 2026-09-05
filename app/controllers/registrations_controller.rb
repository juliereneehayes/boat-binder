class RegistrationsController < ApplicationController
  CHECK_EMAIL_NOTICE = "If the email can be used for registration, verification instructions will arrive shortly."
  RATE_LIMIT_STORE = Rails.env.test? ? ActiveSupport::Cache::MemoryStore.new : Rails.cache

  allow_unauthenticated_access
  before_action :redirect_authenticated_user
  rate_limit to: 5, within: 15.minutes, only: :create,
    store: RATE_LIMIT_STORE,
    with: -> { redirect_to new_registration_path, alert: "Try again later." }

  def new
    @registration = SelfServiceRegistration.new
  end

  def create
    @registration = SelfServiceRegistration.new(registration_params).call

    if @registration.accepted?
      flash[:registration_submitted] = true
      redirect_to new_registration_path, status: :see_other
    else
      render :new, status: :unprocessable_entity
    end
  end

  private

  def registration_params
    params.expect(registration: %i[name email_address password password_confirmation])
  end

  def redirect_authenticated_user
    redirect_to root_path if authenticated?
  end
end
