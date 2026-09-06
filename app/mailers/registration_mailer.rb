class RegistrationMailer < ApplicationMailer
  def existing_address(email_address)
    @sign_in_url = new_session_url
    @password_reset_url = new_password_url

    mail subject: "Boat Binder account request", to: email_address
  end
end
