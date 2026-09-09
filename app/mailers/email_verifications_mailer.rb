class EmailVerificationsMailer < ApplicationMailer
  def verify(user)
    @user = user
    token = user.generate_token_for(:email_verification)
    @verification_url = "#{email_verification_url}#token=#{ERB::Util.url_encode(token)}"

    mail subject: "Verify your Boat Binder email", to: user.email_address
  end
end
