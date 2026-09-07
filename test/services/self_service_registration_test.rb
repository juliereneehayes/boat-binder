require "test_helper"
require "stringio"

class SelfServiceRegistrationTest < ActiveSupport::TestCase
  setup do
    ActionMailer::Base.deliveries.clear
  end

  teardown do
    ActionMailer::Base.deliveries.clear
  end

  test "creates exactly one isolated pending registration graph" do
    registration = build_registration

    assert_difference -> { User.count }, 1 do
      assert_difference -> { Account.count }, 1 do
        assert_difference -> { AccountMembership.count }, 1 do
          assert_difference -> { Subscription.count }, 1 do
            assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
              registration.call
            end
          end
        end
      end
    end

    assert registration.accepted?
    assert registration.created?
    assert_not registration.duplicate?
    assert_not registration.delivery_failed?

    user = registration.user.reload
    account = registration.account.reload
    membership = registration.membership.reload
    subscription = registration.subscription.reload

    assert_equal "owner", user.role
    assert_not user.active?
    assert user.email_verification_pending?
    assert_not user.invitation_pending?
    assert user.authenticate("correct horse battery staple")
    assert_equal "New Owner", user.name
    assert_equal "new-owner@example.test", user.email_address

    assert account.active?
    assert_equal "client", account.account_type
    assert_equal user.name, account.name
    assert_equal Account::DEFAULT_TIME_ZONE, account.time_zone

    assert membership.active?
    assert_equal "editor", membership.access_level
    assert_equal user, membership.user
    assert_equal account, membership.account

    assert subscription.pending_checkout?
    assert_equal account, subscription.account
    assert_nil subscription.external_customer_id
    assert_nil subscription.external_subscription_id
    assert_nil subscription.trial_ends_at
    assert_nil subscription.current_period_ends_at
    assert_nil subscription.last_synced_at

    entitlement = Billing::SelfManagedEntitlement.new(account:)
    assert_not entitlement.qualifying?
    assert_equal :awaiting_checkout, entitlement.reason
    assert_equal :awaiting_checkout, entitlement.lifecycle_phase
    assert_equal 0, Session.where(user:).count
    assert_equal 1, user.account_memberships.count
    assert_equal 1, account.account_memberships.count
  end

  test "rolls the whole graph back at every persistence failure point" do
    %i[user account subscription membership].each do |failure_point|
      registration = build_registration(
        email_address: "#{failure_point}@example.test",
        name: "Failure at #{failure_point}"
      )
      failing_record = registration.public_send(failure_point)
      failing_record.errors.add(:base, "Injected #{failure_point} failure")
      failing_record.define_singleton_method(:save!) do
        raise ActiveRecord::RecordInvalid, self
      end

      assert_no_difference -> { User.count } do
        assert_no_difference -> { Account.count } do
          assert_no_difference -> { AccountMembership.count } do
            assert_no_difference -> { Subscription.count } do
              assert_no_difference -> { ActionMailer::Base.deliveries.size } do
                registration.call
              end
            end
          end
        end
      end

      assert_not registration.accepted?, failure_point.to_s
      assert_includes registration.errors[:base], SelfServiceRegistration::GENERIC_FAILURE_MESSAGE
    end
  end

  test "normalizes email and sends a token-free notification for an existing address" do
    existing_user = create_user(email: "existing@example.test")
    existing_user_state = existing_user.attributes
    registration = build_registration(email_address: "  EXISTING@EXAMPLE.TEST  ")

    assert_no_difference -> { User.count } do
      assert_no_difference -> { Account.count } do
        assert_no_difference -> { AccountMembership.count } do
          assert_no_difference -> { Subscription.count } do
            assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
              registration.call
            end
          end
        end
      end
    end

    assert registration.accepted?
    assert registration.duplicate?
    assert_not registration.created?
    assert_not registration.delivery_failed?
    assert_empty registration.errors
    assert registration.user.authenticate("correct horse battery staple")
    assert_equal existing_user_state, existing_user.reload.attributes

    mail = ActionMailer::Base.deliveries.last
    assert_equal [ "existing@example.test" ], mail.to
    assert_equal "Boat Binder account request", mail.subject
    assert_includes mail_body(mail), "http://example.com/session/new"
    assert_includes mail_body(mail), "http://example.com/passwords/new"
    assert_not_includes mail_body(mail), "/email-verifications/"
    assert_not_includes mail_body(mail), "/invitations/"
  end

  test "delivery failure preserves a safe recoverable registration" do
    registration = build_registration(email_address: "delivery-failure@example.test")
    baseline_open_transactions = ActiveRecord::Base.connection.open_transactions
    delivery_open_transactions = nil
    failed_delivery = Object.new
    failed_delivery.define_singleton_method(:deliver_now) do
      delivery_open_transactions = ActiveRecord::Base.connection.open_transactions
      ActionMailer::Base.logger.error(
        "Failed delivery recipient=delivery-failure@example.test token=verification-secret-value"
      )
      raise Errno::ECONNREFUSED,
        "recipient=delivery-failure@example.test token=verification-secret-value"
    end
    output = StringIO.new
    previous_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(output)
    previous_mailer_logger = ActionMailer::Base.logger
    ActionMailer::Base.logger = Rails.logger

    with_singleton_method(EmailVerificationsMailer, :verify, ->(_user) { failed_delivery }) do
      registration.call
    end

    assert registration.accepted?
    assert registration.created?
    assert registration.delivery_failed?
    assert_equal baseline_open_transactions, delivery_open_transactions
    assert registration.user.reload.email_verification_pending?
    assert_not registration.user.active?
    assert registration.subscription.reload.pending_checkout?
    assert_equal 0, Session.where(user: registration.user).count
    assert_includes output.string, "user_id=#{registration.user.id}"
    assert_includes output.string, "account_id=#{registration.account.id}"
    assert_includes output.string, "Registration verification email delivery failed"
    assert_includes output.string, "Errno::ECONNREFUSED"
    assert_not_includes output.string, registration.user.email_address
    assert_not_includes output.string, "verification-secret-value"
    assert_not_includes output.string, "recipient="
  ensure
    ActionMailer::Base.logger = previous_mailer_logger if previous_mailer_logger
    Rails.logger = previous_logger if previous_logger
  end

  test "duplicate notification delivery failure is accepted without changing the existing user or logging PII" do
    existing_user = create_user(email: "duplicate-delivery@example.test")
    existing_user_state = existing_user.attributes
    registration = build_registration(email_address: " DUPLICATE-DELIVERY@EXAMPLE.TEST ")
    baseline_open_transactions = ActiveRecord::Base.connection.open_transactions
    delivery_open_transactions = nil
    failed_delivery = Object.new
    failed_delivery.define_singleton_method(:deliver_now) do
      ActionMailer::Base.logger.error(
        "Failed delivery recipient=duplicate-delivery@example.test token=duplicate-secret-value"
      )
      delivery_open_transactions = ActiveRecord::Base.connection.open_transactions
      raise Errno::ECONNREFUSED,
        "recipient=duplicate-delivery@example.test token=duplicate-secret-value"
    end
    output = StringIO.new
    previous_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(output)
    previous_mailer_logger = ActionMailer::Base.logger
    ActionMailer::Base.logger = Rails.logger
    delivered_to = nil

    assert_no_difference -> { User.count } do
      assert_no_difference -> { Account.count } do
        assert_no_difference -> { AccountMembership.count } do
          assert_no_difference -> { Subscription.count } do
            with_singleton_method(RegistrationMailer, :existing_address, ->(email_address) {
              delivered_to = email_address
              failed_delivery
            }) do
              registration.call
            end
          end
        end
      end
    end

    assert registration.accepted?
    assert registration.duplicate?
    assert_not registration.created?
    assert registration.delivery_failed?
    assert_equal "duplicate-delivery@example.test", delivered_to
    assert_equal baseline_open_transactions, delivery_open_transactions
    assert_equal existing_user_state, existing_user.reload.attributes
    assert_includes output.string, "Registration existing-address notification delivery failed"
    assert_includes output.string, "Errno::ECONNREFUSED"
    assert_not_includes output.string, "duplicate-delivery@example.test"
    assert_not_includes output.string, "duplicate-secret-value"
    assert_not_includes output.string, "recipient="
  ensure
    ActionMailer::Base.logger = previous_mailer_logger if previous_mailer_logger
    Rails.logger = previous_logger if previous_logger
  end

  private

  def build_registration(overrides = {})
    SelfServiceRegistration.new({
      name: "  New   Owner  ",
      email_address: " New-Owner@Example.Test ",
      password: "correct horse battery staple",
      password_confirmation: "correct horse battery staple"
    }.merge(overrides))
  end

  def with_singleton_method(receiver, method_name, replacement)
    original_method = receiver.method(method_name)
    receiver.define_singleton_method(method_name, replacement)

    yield
  ensure
    receiver.define_singleton_method(method_name, original_method)
  end

  def mail_body(mail)
    [ mail.text_part&.body&.decoded, mail.html_part&.body&.decoded, mail.body.decoded ].compact.join("\n")
  end
end
