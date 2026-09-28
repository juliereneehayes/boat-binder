require "test_helper"

class UserEmailChangeTest < ActiveSupport::TestCase
  test "email change token expires and is bound to pending state" do
    user = create_user(email: "email-change-token@example.test")
    user.update!(
      pending_email_address: "new-email-change-token@example.test",
      email_change_requested_at: Time.current
    )
    token = user.generate_token_for(:email_change)

    assert_not_includes User.column_names, "email_change_token"
    assert_equal user, User.find_by_token_for!(:email_change, token)

    travel User::EMAIL_CHANGE_EXPIRES_IN + 1.second do
      assert_raises(ActiveSupport::MessageVerifier::InvalidSignature) do
        User.find_by_token_for!(:email_change, token)
      end
    end

    user.update!(email_change_requested_at: 1.second.from_now)
    assert_raises(ActiveSupport::MessageVerifier::InvalidSignature) do
      User.find_by_token_for!(:email_change, token)
    end

    replacement_token = user.generate_token_for(:email_change)
    user.update!(email_address: "authoritative-email-changed@example.test")
    assert_raises(ActiveSupport::MessageVerifier::InvalidSignature) do
      User.find_by_token_for!(:email_change, replacement_token)
    end

    replacement_token = user.generate_token_for(:email_change)
    user.update!(pending_email_address: nil, email_change_requested_at: nil)
    assert_raises(ActiveSupport::MessageVerifier::InvalidSignature) do
      User.find_by_token_for!(:email_change, replacement_token)
    end
  end

  test "pending email normalization validation and lifecycle match authoritative email behavior" do
    existing = create_user(email: "existing-email-change@example.test")
    user = create_user(email: "email-change-validation@example.test")

    user.assign_attributes(
      pending_email_address: "  NEW-EMAIL-CHANGE@EXAMPLE.TEST ",
      email_change_requested_at: Time.current
    )
    assert user.valid?
    assert_equal "new-email-change@example.test", user.pending_email_address

    user.pending_email_address = existing.email_address
    assert_not user.valid?
    assert_includes user.errors[:pending_email_address], "has already been taken"

    user.pending_email_address = user.email_address
    assert_not user.valid?
    assert_includes user.errors[:pending_email_address], "has already been taken"

    user.pending_email_address = nil
    assert_not user.valid?
    assert_includes user.errors[:pending_email_address], "can't be blank"
  end

  test "database requires pending email and request timestamp together" do
    user = create_user(email: "email-change-db-pair@example.test")

    assert_raises(ActiveRecord::StatementInvalid) do
      User.transaction(requires_new: true) do
        user.update_column(:pending_email_address, "unpaired@example.test")
      end
    end
  end
end
