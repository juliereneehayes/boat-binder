require "test_helper"

module SecurityAudit
  class RecorderTest < ActiveSupport::TestCase
    setup do
      @actor = create_user(email: "audit-recorder-actor@example.test", role: "admin")
      @target = create_user(email: "audit-recorder-target@example.test", role: "captain")
      @account = create_account(name: "Audit Recorder Account")
      create_account_membership(user: @target, account: @account)
    end

    test "records normalized identifiers and field names through one API" do
      event = Recorder.record!(
        action: "mfa.enrollment_completed",
        actor: @actor,
        account: @account,
        target: @target,
        request_id: "request-123",
        source_ip: "192.0.2.10",
        changed_fields: [ :role, "active", :role ]
      )

      assert_equal @actor, event.actor_user
      assert_equal @account, event.account
      assert_equal "User", event.target_type
      assert_equal @target.id, event.target_id
      assert_equal "request-123", event.request_id
      assert_equal "succeeded", event.outcome
      assert_equal IPAddr.new("192.0.2.10"), event.source_ip
      assert_equal %w[active role], event.changed_fields
      assert event.created_at.present?
    end

    test "account scope does not return another account event" do
      other_account = create_account(name: "Other Audit Recorder Account")
      create_account_membership(user: @target, account: other_account)
      own_event = Recorder.record!(action: "mfa.recovery_codes_regenerated", account: @account, target: @target)
      Recorder.record!(action: "mfa.recovery_code_used", account: other_account, target: @target)

      assert_equal [ own_event ], SecurityAuditEvent.for_account(@account).to_a
    end

    test "rejects an account that does not contain the target user" do
      unrelated_account = create_account(name: "Unrelated Audit Recorder Account")

      error = assert_raises(ArgumentError) do
        Recorder.record!(action: "mfa.enrollment_completed", account: unrelated_account, target: @target)
      end

      assert_equal "account does not match the audit target", error.message
      assert_equal 0, SecurityAuditEvent.count
    end

    test "rejects unknown and value-shaped changed field names" do
      [ "email_address", "password_is_some_secret", TEST_PASSWORD ].each do |unsafe_field|
        error = assert_raises(ActiveRecord::RecordInvalid) do
          Recorder.record!(
            action: "mfa.reset_completed",
            target: @target,
            changed_fields: [ unsafe_field ]
          )
        end

        assert_includes error.record.errors[:changed_fields],
          "must contain only approved semantic field names"
      end

      assert_equal 0, SecurityAuditEvent.count
    end

    test "schema has no generic payload or secret value columns" do
      forbidden_columns = %w[
        metadata payload password password_digest recovery_code session_id token totp_code totp_secret
      ]

      assert_empty SecurityAuditEvent.column_names & forbidden_columns
    end
  end
end
