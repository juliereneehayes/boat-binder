require "application_system_test_case"

class MfaRecoveryCodesSystemTest < ApplicationSystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1200, 900 ]

  test "enrollment and regeneration display their one-time recovery codes" do
    owner = create_user(email: "browser-mfa-recovery@example.test", role: "owner")
    sign_in(owner)

    visit settings_path
    click_button "Set up MFA"
    assert_current_path settings_mfa_enrollment_path
    secret = owner.reload.mfa_enrollment_secret
    fill_in "Verification code", with: current_totp(secret)
    click_button "Confirm and enable MFA"

    assert_selector "ol li code", count: 10, wait: 10
    assert_current_path settings_mfa_enrollment_path
    assert_text "Save your recovery codes"
    initial_codes = all("ol li code").map(&:text)
    assert_equal 10, initial_codes.length
    initial_codes.each { |code| assert_not_includes page.current_url, code }

    click_link "I saved my recovery codes"
    within "form[action='#{settings_mfa_recovery_codes_path}']" do
      fill_in "Current password", with: TEST_PASSWORD
      click_button "Generate new recovery codes"
    end

    assert_selector "ol li code", count: 10, wait: 10
    assert_current_path settings_mfa_recovery_codes_path
    assert_text "Save your recovery codes"
    replacement_codes = all("ol li code").map(&:text)
    assert_equal 10, replacement_codes.length
    assert_not_equal initial_codes.sort, replacement_codes.sort
    replacement_codes.each { |code| assert_not_includes page.current_url, code }
    assert_not owner.reload.consume_mfa_recovery_code!(initial_codes.first)
  end

  private

  def sign_in(user)
    visit new_session_path
    fill_in "Email", with: user.email_address
    fill_in "Password", with: TEST_PASSWORD
    click_button "Sign in"
    assert_current_path root_path
  end

  def current_totp(secret)
    ROTP::TOTP.new(secret, issuer: "Boat Binder", digits: 6, interval: 30).now
  end
end
