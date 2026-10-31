require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :rack_test

  def sign_in_with_browser(user)
    visit new_session_path
    fill_in "Email", with: user.email_address
    fill_in "Password", with: TEST_PASSWORD
    click_button "Sign in"

    if page.has_current_path?(settings_mfa_enrollment_path)
      secret = user.reload.mfa_enrollment_secret
      fill_in "Verification code", with: ROTP::TOTP.new(
        secret,
        issuer: "Boat Binder",
        digits: 6,
        interval: 30
      ).now
      click_button "Confirm and enable MFA"
      assert_selector "ol li code", count: 10, wait: 10
      click_link "I saved my recovery codes"
    end

    assert_current_path root_path
  end
end
