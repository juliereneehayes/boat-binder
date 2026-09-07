class EmailVerificationsMailer < ApplicationMailer
  def verify(user)
    @user = user
    token = user.generate_token_for(:email_verification)
    @verification_url = "#{root_url.chomp("/")}/email-verifications/#{ERB::Util.url_encode(token)}"

    mail subject: "Verify your Boat Binder email", to: user.email_address
  end
end
