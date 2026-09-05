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

  test "normalizes email consistently and treats an existing address as accepted without creating records" do
    existing_user = create_user(email: "existing@example.test")
    registration = build_registration(email_address: "  EXISTING@EXAMPLE.TEST  ")

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

    assert registration.accepted?
    assert registration.duplicate?
    assert_not registration.created?
    assert_empty registration.errors
    assert_equal existing_user, User.find_by!(email_address: "existing@example.test")
  end

  test "delivery failure preserves a safe recoverable registration" do
    registration = build_registration(email_address: "delivery-failure@example.test")
    baseline_open_transactions = ActiveRecord::Base.connection.open_transactions
    delivery_open_transactions = nil
    failed_delivery = Object.new
    failed_delivery.define_singleton_method(:deliver_now) do
      delivery_open_transactions = ActiveRecord::Base.connection.open_transactions
      raise Errno::ECONNREFUSED, "connect(2) for localhost port 25"
    end
    output = StringIO.new
    previous_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(output)

    EmailVerificationsMailer.stub(:verify, ->(_user) { failed_delivery }) do
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
    assert_includes output.string, "Errno::ECONNREFUSED"
    assert_not_includes output.string, registration.user.email_address
  ensure
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
end
