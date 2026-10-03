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
    definition = User.token_definitions.fetch(:email_change)
    decoded_payload = User.generated_token_verifier.verified(token, purpose: definition.full_purpose)
    assert_match(/\A[0-9a-f]{64}\z/, decoded_payload.second)
    assert_not_includes token, user.email_address
    assert_not_includes token, user.pending_email_address
    assert_not_includes decoded_payload.to_json, user.email_address
    assert_not_includes decoded_payload.to_json, user.pending_email_address

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
    user.update!(pending_email_address: "replacement-pending-token@example.test")
    assert_raises(ActiveSupport::MessageVerifier::InvalidSignature) do
      User.find_by_token_for!(:email_change, replacement_token)
    end

    replacement_token = user.generate_token_for(:email_change)
    user.update!(email_address: "authoritative-email-changed@example.test")
    assert_raises(ActiveSupport::MessageVerifier::InvalidSignature) do
      User.find_by_token_for!(:email_change, replacement_token)
    end

    replacement_token = user.generate_token_for(:email_change)
    user.update!(active: false)
    assert_raises(ActiveSupport::MessageVerifier::InvalidSignature) do
      User.find_by_token_for!(:email_change, replacement_token)
    end

    user.update!(active: true)
    replacement_token = user.generate_token_for(:email_change)
    user.update!(pending_email_address: nil, email_change_requested_at: nil)
    assert_raises(ActiveSupport::MessageVerifier::InvalidSignature) do
      User.find_by_token_for!(:email_change, replacement_token)
    end
  end

  test "pending email state is active only for the token lifetime and does not reserve an address" do
    requested_at = Time.current
    user = create_user(email: "pending-email-lifetime@example.test")
    user.update!(
      pending_email_address: "shared-pending-email@example.test",
      email_change_requested_at: requested_at
    )

    assert user.email_change_pending?
    travel_to requested_at + User::EMAIL_CHANGE_EXPIRES_IN + 1.second do
      assert_not user.email_change_pending?
    end

    other_user = create_user(email: "other-pending-email-lifetime@example.test")
    other_user.update!(
      pending_email_address: user.pending_email_address,
      email_change_requested_at: Time.current
    )

    assert_equal user.pending_email_address, other_user.pending_email_address
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
