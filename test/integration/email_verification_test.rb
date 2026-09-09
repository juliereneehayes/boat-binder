require "test_helper"
require "cgi"
require "stringio"

class EmailVerificationTest < ActionDispatch::IntegrationTest
  setup do
    ActionMailer::Base.deliveries.clear
    EmailVerificationsController::RATE_LIMIT_STORE.clear
  end

  teardown do
    ActionMailer::Base.deliveries.clear
    EmailVerificationsController::RATE_LIMIT_STORE.clear
  end

  test "landing page accepts no token server-side and posts it only through a CSRF form" do
    previous_setting = EmailVerificationsController.allow_forgery_protection
    EmailVerificationsController.allow_forgery_protection = true

    get email_verification_path

    assert_response :success
    assert_equal "/email-verifications", request.path
    assert_not request.params.key?("token")
    assert_select "[data-controller=email-verification]"
    assert_select "form[action='#{email_verification_path}'][method=post][data-turbo=false]" do
      assert_select "input[name=authenticity_token]"
      assert_select "input[name=token]" do |elements|
        assert_nil elements.first["value"]
      end
    end
    assert_not_includes response.body, "#token="
  ensure
    EmailVerificationsController.allow_forgery_protection = previous_setting
  end

  test "fragment controller clears browser history before parsing or submitting" do
    source = Rails.root.join("app/javascript/controllers/email_verification_controller.js").read
    replace_history = source.index("history.replaceState")
    parse_fragment = source.index("this.verificationToken(fragment)")
    submit_form = source.index("this.formTarget.requestSubmit()")

    assert replace_history
    assert parse_fragment
    assert submit_form
    assert_operator replace_history, :<, parse_fragment
    assert_operator replace_history, :<, submit_form
  end

  test "valid token performs one verified activation and normal session handoff without Stripe" do
    registration = create_pending_registration
    user = registration.user.reload
    account = registration.account.reload
    membership = registration.membership.reload
    subscription = registration.subscription.reload
    token = user.generate_token_for(:email_verification)
    original_account = account.attributes
    original_membership = membership.attributes
    original_subscription = subscription.attributes

    with_singleton_method(Stripe::Checkout::Session, :create, ->(*) { flunk "Verification must not call Stripe" }) do
      assert_no_difference -> { User.count } do
        assert_no_difference -> { Account.count } do
          assert_no_difference -> { AccountMembership.count } do
            assert_no_difference -> { Subscription.count } do
              assert_difference -> { Session.where(user:).count }, 1 do
                post email_verification_path,
                  params: { token: },
                  headers: { "HTTP_USER_AGENT" => "Boat Binder verification test" }
              end
            end
          end
        end
      end
    end

    assert_redirected_to billing_checkout_path
    assert_equal "Email verified. Choose your Self Managed plan.", flash[:notice]

    user.reload
    assert user.active?
    assert user.email_verified_at.present?
    assert_not user.email_verification_pending?
    assert_equal 1, user.sessions.count
    assert_equal "Boat Binder verification test", user.sessions.sole.user_agent
    assert_raises(ActiveSupport::MessageVerifier::InvalidSignature) do
      User.find_by_token_for!(:email_verification, token)
    end

    assert_equal original_account, account.reload.attributes
    assert_equal original_membership, membership.reload.attributes
    assert membership.active?
    assert_equal "editor", membership.access_level
    assert_equal original_subscription, subscription.reload.attributes
    assert subscription.pending_checkout?
    entitlement = Billing::SelfManagedEntitlement.new(account:)
    assert_not entitlement.qualifying?
    assert_equal :awaiting_checkout, entitlement.reason
    assert_nil subscription.trial_ends_at
    assert_nil subscription.current_period_ends_at
  end

  test "invalid malformed expired and reused tokens share generic recovery without authentication" do
    malformed = "not-a-valid-token"
    assert_generic_verification_failure(malformed)

    registration = create_pending_registration(email: "expired-verification@example.test")
    user = registration.user.reload
    expired_token = travel_to(25.hours.ago) { user.generate_token_for(:email_verification) }
    assert_generic_verification_failure(expired_token)
    assert_not user.reload.active?

    fresh_registration = create_pending_registration(email: "reused-verification@example.test")
    reused_user = fresh_registration.user.reload
    reused_token = reused_user.generate_token_for(:email_verification)
    post email_verification_path, params: { token: reused_token }
    assert_redirected_to billing_checkout_path
    delete session_path

    assert_no_difference -> { Session.count } do
      assert_generic_verification_failure(reused_token)
    end
    assert reused_user.reload.active?
  end

  test "old path-token links are retired rather than redirected or consumed" do
    user = create_pending_registration(email: "retired-link@example.test").user.reload
    token = user.generate_token_for(:email_verification)

    assert_no_difference -> { Session.count } do
      get "/email-verifications/#{CGI.escapeURIComponent(token)}"
    end

    assert_response :not_found
    assert_not user.reload.active?
    assert_equal user, User.find_by_token_for!(:email_verification, token)
  end

  test "verification rejects users outside the genuine pending self-service graph" do
    ineligible_user = create_user(email: "inactive-verification@example.test", role: "owner", active: false)
    ineligible_user.update!(email_verification_sent_at: Time.current)
    token = ineligible_user.generate_token_for(:email_verification)

    assert_no_difference -> { Session.count } do
      post email_verification_path, params: { token: }
    end

    assert_redirected_to new_email_verification_path
    assert_equal EmailVerificationsController::VERIFICATION_FAILURE_MESSAGE, flash[:alert]
    assert_not ineligible_user.reload.active?
    assert_nil ineligible_user.email_verified_at
  end

  test "verification fails closed when the self-service account graph is no longer pending and isolated" do
    mutations = {
      "internal role" => ->(registration) { registration.user.update!(role: "captain") },
      "invitation lifecycle" => ->(registration) { registration.user.update!(invitation_sent_at: Time.current) },
      "inactive membership" => ->(registration) { registration.membership.update!(active: false) },
      "read-only membership" => ->(registration) { registration.membership.update!(access_level: "read_only") },
      "inactive account" => ->(registration) { registration.account.update!(active: false) },
      "non-pending subscription" => ->(registration) { registration.subscription.update!(status: "active") }
    }

    mutations.each_with_index do |(description, mutation), index|
      registration = create_pending_registration(email: "changed-graph-#{index}@example.test")
      mutation.call(registration)
      user = registration.user.reload
      token = user.generate_token_for(:email_verification)

      assert_no_difference -> { Session.count }, description do
        post email_verification_path, params: { token: }
      end

      assert_redirected_to new_email_verification_path, description
      assert_not user.reload.active?, description
      assert_nil user.email_verified_at, description
    end
  end

  test "verified activation rolls back and does not authenticate when persistence fails" do
    user = create_pending_registration(email: "persistence-failure@example.test").user.reload
    token = user.generate_token_for(:email_verification)
    original_update = user.method(:update!)
    user.define_singleton_method(:update!) { |*| raise ActiveRecord::RecordInvalid, self }

    with_singleton_method(User, :find_by_token_for!, ->(*) { user }) do
      assert_no_difference -> { Session.count } do
        post email_verification_path, params: { token: }
      end
    end

    assert_redirected_to new_email_verification_path
    assert_not user.reload.active?
    assert_nil user.email_verified_at
  ensure
    user&.define_singleton_method(:update!, original_update) if original_update
  end

  test "authenticated browsers are redirected before token lookup and cannot switch identity" do
    signed_in_user = create_user(email: "already-signed-in@example.test", role: "admin", name: "Current Admin")
    target = create_pending_registration(email: "switch-target@example.test").user.reload
    token = target.generate_token_for(:email_verification)
    sign_in_as signed_in_user
    current_session_ids = signed_in_user.sessions.pluck(:id)

    with_singleton_method(User, :find_by_token_for!, ->(*) { flunk "Token lookup must not run" }) do
      get email_verification_path
      assert_redirected_to root_path

      post email_verification_path, params: { token: }
      assert_redirected_to root_path
    end

    assert_equal EmailVerificationsController::AUTHENTICATED_VERIFICATION_MESSAGE, flash[:alert]
    assert_equal current_session_ids, signed_in_user.sessions.reload.pluck(:id)
    assert_not target.reload.active?
    assert_equal target, User.find_by_token_for!(:email_verification, token)
  end

  test "eligible resend normalizes email rotates token and sends one fragment link on configured host" do
    registration = create_pending_registration(email: "resend-owner@example.test")
    user = registration.user.reload
    old_sent_at = user.email_verification_sent_at
    old_token = user.generate_token_for(:email_verification)
    previous_options = EmailVerificationsMailer.default_url_options
    EmailVerificationsMailer.default_url_options = previous_options.merge(
      host: "staging.boat-binder.com",
      protocol: "https"
    )

    assert_no_difference -> { User.count } do
      assert_no_difference -> { Account.count } do
        assert_no_difference -> { AccountMembership.count } do
          assert_no_difference -> { Subscription.count } do
            assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
              post resend_email_verification_path,
                params: { email_address: "  RESEND-OWNER@EXAMPLE.TEST  " }
            end
          end
        end
      end
    end

    assert_redirected_to new_email_verification_path
    assert_equal EmailVerificationsController::RESEND_NOTICE, flash[:notice]
    assert_operator user.reload.email_verification_sent_at, :>, old_sent_at
    assert_raises(ActiveSupport::MessageVerifier::InvalidSignature) do
      User.find_by_token_for!(:email_verification, old_token)
    end

    mail = ActionMailer::Base.deliveries.last
    new_token = verification_token_from(mail)
    assert_equal [ user.email_address ], mail.to
    assert_includes mail_body(mail), "https://staging.boat-binder.com/email-verifications#token="
    assert_not_includes mail_body(mail), "/email-verifications/"
    assert_equal user, User.find_by_token_for!(:email_verification, new_token)
    assert_not user.active?
    assert_nil user.email_verified_at
    assert_equal 0, user.sessions.count
  ensure
    EmailVerificationsMailer.default_url_options = previous_options if previous_options
  end

  test "resend response is identical and sends nothing for nonexistent or ineligible users" do
    active_user = create_user(email: "active-resend@example.test")
    inactive_user = create_user(email: "inactive-resend@example.test", role: "owner", active: false)
    inactive_user.update!(email_verification_sent_at: Time.current)
    invited_user = User.create!(
      email_address: "invited-resend@example.test",
      role: "owner",
      active: false,
      invitation_sent_at: Time.current
    )
    invited_user.update!(email_verification_sent_at: Time.current)
    candidates = [
      "missing-resend@example.test",
      active_user.email_address,
      inactive_user.email_address,
      invited_user.email_address
    ]

    responses = candidates.map.with_index do |email_address, index|
      EmailVerificationsController::RATE_LIMIT_STORE.clear
      assert_no_difference -> { ActionMailer::Base.deliveries.size } do
        post resend_email_verification_path,
          params: { email_address: },
          headers: { "REMOTE_ADDR" => "198.51.100.#{index + 1}" }
      end
      [ response.status, response.location, flash[:notice], response.body ]
    end

    assert_equal 1, responses.uniq.size
    assert_equal EmailVerificationsController::RESEND_NOTICE, flash[:notice]
    assert_not active_user.reload.email_verification_pending?
    assert_not inactive_user.reload.active?
    assert invited_user.reload.invitation_pending?
  end

  test "resend rate limits by IP and normalized email with the same generic response" do
    user = create_pending_registration(email: "limited-resend@example.test").user.reload

    5.times do
      post resend_email_verification_path, params: { email_address: user.email_address }
      assert_redirected_to new_email_verification_path
      assert_equal EmailVerificationsController::RESEND_NOTICE, flash[:notice]
    end

    assert_no_difference -> { ActionMailer::Base.deliveries.size } do
      post resend_email_verification_path, params: { email_address: user.email_address }
    end
    assert_redirected_to new_email_verification_path
    assert_equal EmailVerificationsController::RESEND_NOTICE, flash[:notice]

    EmailVerificationsController::RATE_LIMIT_STORE.clear
    5.times do |index|
      submitted_email = index.even? ? "  LIMITED-RESEND@EXAMPLE.TEST  " : user.email_address
      post resend_email_verification_path,
        params: { email_address: submitted_email },
        headers: { "REMOTE_ADDR" => "203.0.113.#{index + 1}" }
      assert_redirected_to new_email_verification_path
    end

    assert_no_difference -> { ActionMailer::Base.deliveries.size } do
      post resend_email_verification_path,
        params: { email_address: user.email_address },
        headers: { "REMOTE_ADDR" => "203.0.113.99" }
    end
    assert_equal EmailVerificationsController::RESEND_NOTICE, flash[:notice]
  end

  test "resend delivery failure restores the previous usable token without exposing the failure" do
    user = create_pending_registration(email: "failed-resend@example.test").user.reload
    previous_sent_at = user.email_verification_sent_at
    old_token = user.generate_token_for(:email_verification)
    failed_delivery = Object.new
    failed_delivery.define_singleton_method(:deliver_now) do
      raise Errno::ECONNREFUSED, "recipient=failed-resend@example.test token=raw-mail-secret"
    end
    logs = capture_request_logs do
      with_singleton_method(EmailVerificationsMailer, :verify, ->(*) { failed_delivery }) do
        assert_no_difference -> { ActionMailer::Base.deliveries.size } do
          post resend_email_verification_path, params: { email_address: user.email_address }
        end
      end
    end

    assert_redirected_to new_email_verification_path
    assert_equal EmailVerificationsController::RESEND_NOTICE, flash[:notice]
    assert_equal previous_sent_at, user.reload.email_verification_sent_at
    assert_equal user, User.find_by_token_for!(:email_verification, old_token)
    assert user.email_verification_pending?
    assert_not user.active?
    assert_equal 0, user.sessions.count
    assert_includes logs, "Verification resend email delivery failed"
    assert_includes logs, "Errno::ECONNREFUSED"
    assert_not_includes logs, user.email_address
    assert_not_includes logs, old_token
    assert_not_includes logs, "raw-mail-secret"
  end

  test "verification tokens are filtered from request logs for every result" do
    valid_user = create_pending_registration(email: "logged-valid@example.test").user.reload
    valid_token = valid_user.generate_token_for(:email_verification)
    valid_logs = capture_request_logs do
      post email_verification_path, params: { token: valid_token }
    end
    assert_filtered_token_logs(valid_logs, valid_token)
    delete session_path

    reused_logs = capture_request_logs do
      post email_verification_path, params: { token: valid_token }
    end
    assert_filtered_token_logs(reused_logs, valid_token)

    invalid_token = "a" * 96
    invalid_logs = capture_request_logs do
      post email_verification_path, params: { token: invalid_token }
    end
    assert_filtered_token_logs(invalid_logs, invalid_token)

    expired_user = create_pending_registration(email: "logged-expired@example.test").user.reload
    expired_token = travel_to(25.hours.ago) { expired_user.generate_token_for(:email_verification) }
    expired_logs = capture_request_logs do
      post email_verification_path, params: { token: expired_token }
    end
    assert_filtered_token_logs(expired_logs, expired_token)
  end

  test "resend email token and recipient remain absent from application logs" do
    user = create_pending_registration(email: "private-resend@example.test").user.reload

    logs = capture_request_logs do
      post resend_email_verification_path, params: { email_address: user.email_address }
    end

    token = verification_token_from(ActionMailer::Base.deliveries.last)
    assert_not_includes logs, token
    assert_not_includes logs, user.email_address
  end

  test "verification POST remains protected by CSRF" do
    previous_setting = EmailVerificationsController.allow_forgery_protection
    EmailVerificationsController.allow_forgery_protection = true
    user = create_pending_registration(email: "csrf-verification@example.test").user.reload
    token = user.generate_token_for(:email_verification)

    assert_no_difference -> { Session.count } do
      post email_verification_path, params: { token: }
    end

    assert_response :unprocessable_entity
    assert_not user.reload.active?
  ensure
    EmailVerificationsController.allow_forgery_protection = previous_setting
  end

  private

  def create_pending_registration(email: "verification-owner@example.test")
    registration = SelfServiceRegistration.new(
      name: "Verification Owner",
      email_address: email,
      password: "correct horse battery staple",
      password_confirmation: "correct horse battery staple"
    ).call
    assert registration.created?
    ActionMailer::Base.deliveries.clear
    registration
  end

  def assert_generic_verification_failure(token)
    assert_no_difference -> { Session.count } do
      post email_verification_path, params: { token: }
    end
    assert_redirected_to new_email_verification_path
    assert_equal EmailVerificationsController::VERIFICATION_FAILURE_MESSAGE, flash[:alert]
    follow_redirect!
    assert_response :success
    assert_includes response.body, EmailVerificationsController::VERIFICATION_FAILURE_MESSAGE
    assert_not_includes response.body, token
  end

  def verification_token_from(mail)
    body = mail.text_part&.body&.decoded || mail.body.decoded
    CGI.unescape(body.match(/#token=([^\s<]+)/)[1])
  end

  def mail_body(mail)
    [ mail.text_part&.body&.decoded, mail.html_part&.body&.decoded, mail.body.decoded ].compact.join("\n")
  end

  def capture_request_logs
    output = StringIO.new
    logger = ActiveSupport::Logger.new(output)
    logger.level = Logger::DEBUG
    previous_rails_logger = Rails.logger
    previous_controller_logger = ActionController::Base.logger
    Rails.logger = logger
    ActionController::Base.logger = logger

    yield
    output.string
  ensure
    ActionController::Base.logger = previous_controller_logger if previous_controller_logger
    Rails.logger = previous_rails_logger if previous_rails_logger
  end

  def assert_filtered_token_logs(logs, token)
    assert_not_includes logs, token
    assert_includes logs, "[FILTERED]"
  end

  def with_singleton_method(receiver, method_name, replacement)
    original_method = receiver.method(method_name)
    receiver.define_singleton_method(method_name, replacement)
    yield
  ensure
    receiver.define_singleton_method(method_name, original_method)
  end
end
