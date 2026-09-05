require "test_helper"
require "cgi"
require "stringio"

class SelfServiceRegistrationIntegrationTest < ActionDispatch::IntegrationTest
  setup do
    ActionMailer::Base.deliveries.clear
    RegistrationsController::RATE_LIMIT_STORE.clear
  end

  teardown do
    ActionMailer::Base.deliveries.clear
    RegistrationsController::RATE_LIMIT_STORE.clear
  end

  test "public form collects only the minimal registration fields" do
    get new_registration_path

    assert_response :success
    assert_select "form[action='#{registration_path}'][method='post']"
    assert_select "input[name='registration[name]']"
    assert_select "input[name='registration[email_address]']"
    assert_select "input[name='registration[password]']"
    assert_select "input[name='registration[password_confirmation]']"
    assert_select "input[name='registration[role]']", count: 0
    assert_select "input[name='registration[active]']", count: 0
    assert_select "input[name='registration[account_id]']", count: 0
    assert_select "input[name='registration[access_level]']", count: 0
    assert_select "input[name='registration[provider]']", count: 0
    assert_select "input[name='registration[external_customer_id]']", count: 0
    assert_select "input[name='registration[phone]']", count: 0
    assert_select "input[name='registration[address]']", count: 0
    assert_select "input[name='registration[vessel_name]']", count: 0
    assert_select "input[name='registration[payment_method]']", count: 0
  end

  test "registration ignores privileged tampering and does not authenticate or call Stripe" do
    existing_account = create_account(name: "Existing Account")
    params = registration_params.merge(
      role: "admin",
      active: true,
      account_id: existing_account.id,
      account_type: "internal",
      access_level: "read_only",
      provider: "stripe",
      plan: "professional",
      status: "active",
      external_customer_id: "cus_forged",
      external_subscription_id: "sub_forged",
      trial_ends_at: 7.days.from_now
    )

    Stripe::Checkout::Session.stub(:create, ->(*) { flunk "Registration must not call Stripe" }) do
      assert_difference -> { User.count }, 1 do
        assert_difference -> { Account.count }, 1 do
          assert_difference -> { AccountMembership.count }, 1 do
            assert_difference -> { Subscription.count }, 1 do
              assert_no_difference -> { Session.count } do
                assert_no_difference -> { Asset.count } do
                  assert_no_difference -> { Contact.count } do
                    post registration_path, params: { registration: params }
                  end
                end
              end
            end
          end
        end
      end
    end

    assert_response :see_other
    assert_redirected_to new_registration_path
    assert flash[:registration_submitted]
    follow_redirect!
    assert_response :success
    assert_select "h1", text: "Check your email"
    assert_not_includes response.body, "new-registration@example.test"

    user = User.find_by!(email_address: "new-registration@example.test")
    membership = user.account_memberships.sole
    account = membership.account
    subscription = account.subscription

    assert_equal "owner", user.role
    assert_not user.active?
    assert user.email_verification_pending?
    assert_equal "client", account.account_type
    assert account.active?
    assert_equal "editor", membership.access_level
    assert membership.active?
    assert subscription.pending_checkout?
    assert_nil subscription.external_customer_id
    assert_nil subscription.external_subscription_id
    assert_not_equal existing_account, account
    assert_empty account.billing_checkout_attempts
    assert_equal 0, Session.where(user:).count
    assert_nil cookies[:session_id]

    assert_no_difference -> { Session.count } do
      post session_path, params: {
        email_address: user.email_address,
        password: "correct horse battery staple"
      }
    end
    assert_redirected_to new_session_path
    assert_equal Authentication::GENERIC_LOGIN_FAILURE_MESSAGE, flash[:alert]
  end

  test "new and duplicate email submissions receive the same public response" do
    post registration_path, params: { registration: registration_params(email_address: "brand-new@example.test") }
    new_response = public_response

    active_user = create_user(email: "active-registration@example.test")
    inactive_user = create_user(email: "inactive-registration@example.test", active: false)
    invited_user = User.create!(
      name: "Invited Registration",
      email_address: "invited-registration@example.test",
      role: "owner",
      active: false,
      invitation_sent_at: Time.current
    )
    pending = SelfServiceRegistration.new(
      registration_params(email_address: "pending-registration@example.test")
    ).call.user
    ActionMailer::Base.deliveries.clear

    [ active_user, inactive_user, invited_user, pending ].each do |existing_user|
      assert_no_difference -> { User.count } do
        assert_no_difference -> { Account.count } do
          assert_no_difference -> { AccountMembership.count } do
            assert_no_difference -> { Subscription.count } do
              assert_no_difference -> { ActionMailer::Base.deliveries.size } do
                post registration_path, params: {
                  registration: registration_params(
                    email_address: "  #{existing_user.email_address.upcase}  "
                  )
                }
              end
            end
          end
        end
      end

      assert_equal new_response, public_response
      assert_not_includes response.body, existing_user.email_address
    end
  end

  test "invalid registration rolls back and returns correctable validation errors" do
    assert_no_difference -> { User.count } do
      assert_no_difference -> { Account.count } do
        assert_no_difference -> { AccountMembership.count } do
          assert_no_difference -> { Subscription.count } do
            post registration_path, params: {
              registration: registration_params(password_confirmation: "different")
            }
          end
        end
      end
    end

    assert_response :unprocessable_entity
    assert_select "li", text: "Password confirmation doesn't match Password"
    assert_select "input[name='registration[role]']", count: 0
  end

  test "registration is rate limited" do
    5.times do
      post registration_path, params: {
        registration: registration_params(email_address: "rate-limit@example.test")
      }
      assert_response :see_other
      assert flash[:registration_submitted]
    end

    assert_no_difference -> { User.count } do
      post registration_path, params: {
        registration: registration_params(email_address: "another-rate-limit@example.test")
      }
    end

    assert_redirected_to new_registration_path
    assert_equal "Try again later.", flash[:alert]
    assert_nil User.find_by(email_address: "another-rate-limit@example.test")
  end

  test "CSRF protection remains enabled for registration" do
    previous_setting = RegistrationsController.allow_forgery_protection
    RegistrationsController.allow_forgery_protection = true

    assert_no_difference -> { User.count } do
      assert_no_difference -> { Account.count } do
        post registration_path, params: { registration: registration_params }
      end
    end

    assert_response :unprocessable_entity
  ensure
    RegistrationsController.allow_forgery_protection = previous_setting
  end

  test "verification email uses an independent token without logging it" do
    output = StringIO.new
    previous_logger = Rails.logger
    logger = ActiveSupport::Logger.new(output)
    logger.level = Logger::INFO
    Rails.logger = logger

    post registration_path, params: { registration: registration_params }

    mail = ActionMailer::Base.deliveries.last
    assert_not_nil mail
    assert_equal [ "new-registration@example.test" ], mail.to
    assert_equal "Verify your Boat Binder email", mail.subject

    body = mail.text_part&.body&.decoded || mail.body.decoded
    token = CGI.unescape(body.match(%r{/email-verifications/([^\s<]+)})[1])
    user = User.find_by!(email_address: "new-registration@example.test")

    assert_equal user, User.find_by_token_for!(:email_verification, token)
    assert_not_includes output.string, token
    assert_includes body, "http://example.com/email-verifications/"
    assert_includes body, "24 hours"
  ensure
    Rails.logger = previous_logger if previous_logger
  end

  test "verification email uses the configured application host" do
    previous_options = EmailVerificationsMailer.default_url_options
    EmailVerificationsMailer.default_url_options = previous_options.merge(
      host: "app.boat-binder.com",
      protocol: "https"
    )
    user = SelfServiceRegistration.new(
      registration_params(email_address: "verification-host@example.test")
    ).call.user
    mail = ActionMailer::Base.deliveries.last
    body = mail.text_part&.body&.decoded || mail.body.decoded

    assert_equal [ user.email_address ], mail.to
    assert_includes body, "https://app.boat-binder.com/email-verifications/"
  ensure
    EmailVerificationsMailer.default_url_options = previous_options if previous_options
  end

  test "delivery failure returns generic success and leaves an inactive recoverable record" do
    failed_delivery = Object.new
    failed_delivery.define_singleton_method(:deliver_now) do
      raise Errno::ECONNREFUSED, "connect(2) for localhost port 25"
    end

    EmailVerificationsMailer.stub(:verify, ->(_user) { failed_delivery }) do
      post registration_path, params: {
        registration: registration_params(email_address: "delivery-failure-public@example.test")
      }
    end

    assert_response :see_other
    assert_redirected_to new_registration_path
    assert flash[:registration_submitted]

    user = User.find_by!(email_address: "delivery-failure-public@example.test")
    assert_not user.active?
    assert user.email_verification_pending?
    assert user.account_memberships.sole.account.subscription.pending_checkout?
    assert_equal 0, Session.where(user:).count
  end

  test "authenticated users cannot replace their identity through registration" do
    admin = create_user(email: "signed-in-registration@example.test", role: "admin")
    sign_in_as admin

    assert_no_difference -> { User.count } do
      post registration_path, params: { registration: registration_params }
    end

    assert_redirected_to root_path
    assert_equal admin, Session.order(:id).last.user
  end

  private

  def registration_params(overrides = {})
    {
      name: "New Registration",
      email_address: "new-registration@example.test",
      password: "correct horse battery staple",
      password_confirmation: "correct horse battery staple"
    }.merge(overrides)
  end

  def public_response
    redirect_response = [ response.status, URI(response.location).path, flash[:registration_submitted] ]
    follow_redirect!

    redirect_response + [
      response.status,
      response.body.include?("Check your email"),
      response.body.include?(RegistrationsController::CHECK_EMAIL_NOTICE)
    ]
  end
end
