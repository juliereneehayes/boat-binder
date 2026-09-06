require "openssl"

class RegistrationsController < ApplicationController
  CHECK_EMAIL_NOTICE = "If the email can be used for registration, verification instructions will arrive shortly."
  EMAIL_RATE_LIMIT_KEY_PURPOSE = "registration-email-rate-limit"
  RATE_LIMIT_STORE = Rails.env.test? ? ActiveSupport::Cache::MemoryStore.new : Rails.cache

  allow_unauthenticated_access
  before_action :redirect_authenticated_user
  rate_limit to: 5, within: 15.minutes, only: :create, name: "ip",
    store: RATE_LIMIT_STORE,
    with: -> { redirect_to new_registration_path, alert: "Try again later." }
  rate_limit to: 5, within: 1.hour, only: :create, name: "email",
    by: :registration_email_rate_limit_key,
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

  def registration_email_rate_limit_key
    key = Rails.application.key_generator.generate_key(EMAIL_RATE_LIMIT_KEY_PURPOSE, 32)
    OpenSSL::HMAC.hexdigest("SHA256", key, normalized_registration_email)
  end

  def normalized_registration_email
    registration = params[:registration]
    return "" unless registration.is_a?(ActionController::Parameters) || registration.is_a?(Hash)

    email_address = registration[:email_address]
    email_address.is_a?(String) ? email_address.strip.downcase : ""
  end

  def redirect_authenticated_user
    redirect_to root_path if authenticated?
  end
end
