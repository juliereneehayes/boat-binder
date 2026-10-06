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
    submit_with_guard_assertion(
      "form[action='#{settings_mfa_enrollment_path}'][data-controller='non-turbo-submit']",
      button_text: "Confirm and enable MFA",
      submitting_text: "Verifying..."
    )

    assert_selector "ol li code", count: 10, wait: 10
    assert_current_path settings_mfa_enrollment_path
    assert_text "Save your recovery codes"
    initial_codes = all("ol li code").map(&:text)
    assert_equal 10, initial_codes.length
    initial_codes.each { |code| assert_not_includes page.current_url, code }

    click_link "I saved my recovery codes"
    recovery_form = "form[action='#{settings_mfa_recovery_codes_path}']"
    within recovery_form do
      fill_in "Current password", with: TEST_PASSWORD
    end
    submit_with_guard_assertion(
      recovery_form,
      button_text: "Generate new recovery codes",
      submitting_text: "Generating..."
    )

    assert_selector "ol li code", count: 10, wait: 10
    assert_current_path settings_mfa_recovery_codes_path
    assert_text "Save your recovery codes"
    replacement_codes = all("ol li code").map(&:text)
    assert_equal 10, replacement_codes.length
    assert_not_equal initial_codes.sort, replacement_codes.sort
    replacement_codes.each { |code| assert_not_includes page.current_url, code }
    assert_not owner.reload.consume_mfa_recovery_code!(initial_codes.first)
  end

  test "restricted privileged enrollment creates a Session only after non-Turbo confirmation" do
    admin = create_user(email: "browser-restricted-mfa@example.test", role: "admin")

    with_privileged_mfa_enforcement do
      submit_credentials(admin)
      assert_current_path settings_mfa_enrollment_path
      assert_empty admin.sessions.reload
      assert_selector "form[data-turbo='false'][data-controller='non-turbo-submit']"

      secret = admin.reload.mfa_enrollment_secret
      fill_in "Verification code", with: current_totp(secret)
      submit_with_guard_assertion(
        "form[action='#{settings_mfa_enrollment_path}'][data-controller='non-turbo-submit']",
        button_text: "Confirm and enable MFA",
        submitting_text: "Verifying..."
      )

      assert_selector "ol li code", count: 10, wait: 10
      assert_text "Save your recovery codes"
      assert_equal 10, all("ol li code").length
      assert_equal 1, admin.sessions.reload.count
    end
  end

  private

  def sign_in(user)
    submit_credentials(user)
    assert_current_path root_path
  end

  def submit_credentials(user)
    visit new_session_path
    fill_in "Email", with: user.email_address
    fill_in "Password", with: TEST_PASSWORD
    click_button "Sign in"
  end

  def current_totp(secret)
    ROTP::TOTP.new(secret, issuer: "Boat Binder", digits: 6, interval: 30).now
  end

  def submit_with_guard_assertion(form_selector, button_text:, submitting_text:)
    page.execute_script(<<~JAVASCRIPT, form_selector)
      document.querySelector(arguments[0]).addEventListener(
        "submit",
        (event) => event.preventDefault(),
        { once: true }
      )
    JAVASCRIPT

    within(form_selector) { click_button button_text }
    submit_button = find_button(submitting_text, disabled: true)
    page.execute_script(
      "arguments[0].disabled = false; arguments[0].value = arguments[1]",
      submit_button,
      button_text
    )
    within(form_selector) { click_button button_text }
  end

  def with_privileged_mfa_enforcement
    previous_value = ENV[Mfa::Policy::ENFORCEMENT_ENV]
    ENV[Mfa::Policy::ENFORCEMENT_ENV] = "true"
    yield
  ensure
    if previous_value.nil?
      ENV.delete(Mfa::Policy::ENFORCEMENT_ENV)
    else
      ENV[Mfa::Policy::ENFORCEMENT_ENV] = previous_value
    end
  end
end
