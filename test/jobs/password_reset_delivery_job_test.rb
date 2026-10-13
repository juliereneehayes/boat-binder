require "test_helper"
require "stringio"

class PasswordResetDeliveryJobTest < ActiveJob::TestCase
  setup do
    ActionMailer::Base.deliveries.clear
  end

  teardown do
    ActionMailer::Base.deliveries.clear
  end

  test "expected delivery errors are handled with class-only application logging" do
    user = create_user(email: "private-job-recipient@example.test")
    provider_message = "provider rejected private-job-recipient@example.test at smtp.private.test"
    failed_delivery = Object.new
    failed_delivery.define_singleton_method(:deliver_now) { raise IOError, provider_message }
    original_reset = PasswordsMailer.method(:reset)
    PasswordsMailer.define_singleton_method(:reset) { |_user| failed_delivery }
    log_output = StringIO.new
    original_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(log_output)

    assert_equal false, PasswordResetDeliveryJob.new.perform(user.id)

    assert_includes log_output.string, "user_id=#{user.id}"
    assert_includes log_output.string, "exception_class=IOError"
    assert_not_includes log_output.string, user.email_address
    assert_not_includes log_output.string, provider_message
    assert_empty ActionMailer::Base.deliveries
  ensure
    PasswordsMailer.define_singleton_method(:reset, original_reset) if original_reset
    Rails.logger = original_logger if original_logger
  end

  test "missing user id is a quiet no-op" do
    assert_no_difference -> { ActionMailer::Base.deliveries.size } do
      assert_nil PasswordResetDeliveryJob.new.perform(nil)
    end
  end
end
