require "test_helper"

class VesselAccessInformation::PersistenceTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @account = create_account(name: "Audited Vessel Access Account")
    @account.create_managed_service_relationship!(active: true)
    @vessel = create_vessel(account: @account, name: "Audited Vessel")
    @actor = create_user(email: "vessel-access-auditor@example.test", role: "admin")
    @synthetic_secret = "Synthetic marina lockbox 7281"
  end

  test "create and update are audited with field names but no restricted value" do
    assert_no_enqueued_jobs do
      assert_difference -> { SecurityAuditEvent.count }, 1 do
        @record = VesselAccessInformation::Persistence.save!(
          vessel: @vessel,
          restricted_details: @synthetic_secret,
          actor: @actor,
          request_id: "restricted-create-request"
        )
      end
    end

    create_event = SecurityAuditEvent.order(:id).last
    assert_equal "vessel_access_information.created", create_event.action
    assert_equal @actor, create_event.actor_user
    assert_equal @account, create_event.account
    assert_equal "VesselAccessInformation", create_event.target_type
    assert_equal @record.id, create_event.target_id
    assert_equal %w[restricted_details], create_event.changed_fields
    assert_nil create_event.source_ip
    assert_not_includes create_event.attributes.to_json, @synthetic_secret

    replacement = "Synthetic marina lockbox 9146"
    assert_difference -> { SecurityAuditEvent.count }, 1 do
      VesselAccessInformation::Persistence.save!(
        vessel: @vessel,
        restricted_details: replacement,
        actor: @actor,
        request_id: "restricted-update-request"
      )
    end

    update_event = SecurityAuditEvent.order(:id).last
    assert_equal "vessel_access_information.updated", update_event.action
    assert_equal %w[restricted_details], update_event.changed_fields
    assert_not_includes update_event.attributes.to_json, @synthetic_secret
    assert_not_includes update_event.attributes.to_json, replacement
  end

  test "unchanged details do not create a duplicate audit event" do
    VesselAccessInformation::Persistence.save!(
      vessel: @vessel,
      restricted_details: @synthetic_secret,
      actor: @actor
    )

    assert_no_difference -> { SecurityAuditEvent.count } do
      VesselAccessInformation::Persistence.save!(
        vessel: @vessel,
        restricted_details: @synthetic_secret,
        actor: @actor
      )
    end
  end

  test "nil and blank new details fail validation instead of returning an unsaved record" do
    [ nil, "", "   " ].each do |invalid_details|
      error = assert_raises(ActiveRecord::RecordInvalid) do
        VesselAccessInformation::Persistence.save!(
          vessel: @vessel,
          restricted_details: invalid_details,
          actor: @actor
        )
      end

      assert_includes error.record.errors[:restricted_details], "can't be blank"
      assert_equal 0, VesselAccessInformation.count
      assert_equal 0, SecurityAuditEvent.count
    end
  end

  test "length boundary succeeds and an oversized update preserves the encrypted record" do
    maximum = "a" * VesselAccessInformation::MAX_RESTRICTED_DETAILS_LENGTH
    record = VesselAccessInformation::Persistence.save!(
      vessel: @vessel,
      restricted_details: maximum,
      actor: @actor
    )

    oversized = "b" * (VesselAccessInformation::MAX_RESTRICTED_DETAILS_LENGTH + 1)
    error = assert_raises(ActiveRecord::RecordInvalid) do
      VesselAccessInformation::Persistence.save!(
        vessel: @vessel,
        restricted_details: oversized,
        actor: @actor
      )
    end

    assert_includes error.record.errors[:restricted_details],
      "is too long (maximum is #{VesselAccessInformation::MAX_RESTRICTED_DETAILS_LENGTH} characters)"
    assert_equal maximum, record.reload.restricted_details
    assert_equal 1, SecurityAuditEvent.count
  end
end
