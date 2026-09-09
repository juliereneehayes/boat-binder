require "application_system_test_case"
require "cgi"

class EmailVerificationSystemTest < ApplicationSystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1200, 900 ]

  setup do
    ActionMailer::Base.deliveries.clear
    @registration = SelfServiceRegistration.new(
      name: "Browser Verification Owner",
      email_address: "browser-verification@example.test",
      password: "correct horse battery staple",
      password_confirmation: "correct horse battery staple"
    ).call
    @user = @registration.user.reload
    ActionMailer::Base.deliveries.clear
  end

  test "fragment token is removed before the CSRF POST verifies and redirects" do
    token = @user.generate_token_for(:email_verification)

    visit "#{email_verification_path}#token=#{CGI.escapeURIComponent(token)}"

    assert_current_path billing_checkout_path
    assert_text "Choose your billing schedule"
    assert_not_includes page.current_url, token
    assert_not_includes page.current_url, "#token="
    assert @user.reload.active?
    assert @user.email_verified_at.present?
    assert_equal 1, @user.sessions.count
  end

  test "missing or malformed fragments show generic recovery without a lookup" do
    [ email_verification_path, "#{email_verification_path}#token=malformed" ].each do |location|
      visit location

      assert_current_path email_verification_path
      assert_text EmailVerificationsController::VERIFICATION_FAILURE_MESSAGE
      assert_link "Request a new verification email", href: new_email_verification_path
      assert_not @user.reload.active?
      assert_nil @user.email_verified_at
      assert_equal 0, @user.sessions.count
    end
  end
end
