class EmailChangesMailer < ApplicationMailer
  def verify(user)
    @user = user.reload
    token = @user.generate_token_for(:email_change)
    @verification_url = "#{email_change_confirmation_url}#token=#{ERB::Util.url_encode(token)}"

    mail subject: "Verify your new Boat Binder email", to: @user.pending_email_address
  end
end
