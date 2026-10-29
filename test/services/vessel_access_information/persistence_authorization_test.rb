require "test_helper"

class VesselAccessInformation::PersistenceAuthorizationTest < ActiveSupport::TestCase
  setup do
    @managed_account = create_account(name: "Persistence Authorization Managed")
    @managed_account.create_managed_service_relationship!(active: true)
    @managed_vessel = create_vessel(account: @managed_account, name: "Managed Persistence Vessel")

    @other_managed_account = create_account(name: "Persistence Authorization Other")
    @other_managed_account.create_managed_service_relationship!(active: true)
    @other_managed_vessel = create_vessel(
      account: @other_managed_account,
      name: "Other Managed Persistence Vessel"
    )

    @self_managed_account = create_account(name: "Persistence Authorization Self Managed")
    @self_managed_vessel = create_vessel(
      account: @self_managed_account,
      name: "Self Managed Persistence Vessel"
    )
  end

  test "restricted mutation denies unauthorized roles and account contexts without disclosing details" do
    admin_without_managed_service = create_user(email: "denied-admin@example.test", role: "admin")
    captain_without_managed_service = create_user(email: "denied-captain@example.test", role: "captain")
    inactive_admin = create_user(email: "denied-inactive-admin@example.test", role: "admin", active: false)
    read_only_owner = create_user(email: "denied-read-only-owner@example.test", role: "owner")
    create_account_membership(user: read_only_owner, account: @managed_account, access_level: "read_only")
    unqualified_owner = create_user(email: "denied-unqualified-owner@example.test", role: "owner")
    create_account_membership(user: unqualified_owner, account: @self_managed_account, access_level: "editor")
    cross_account_owner = create_user(email: "denied-cross-account-owner@example.test", role: "owner")
    create_account_membership(user: cross_account_owner, account: @managed_account, access_level: "editor")

    denied_attempts = [
      [ admin_without_managed_service, @self_managed_vessel ],
      [ captain_without_managed_service, @self_managed_vessel ],
      [ inactive_admin, @managed_vessel ],
      [ read_only_owner, @managed_vessel ],
      [ unqualified_owner, @self_managed_vessel ],
      [ cross_account_owner, @other_managed_vessel ],
      [ nil, @managed_vessel ]
    ]

    denied_attempts.each_with_index do |(actor, vessel), index|
      synthetic_secret = "Synthetic denied value #{index}"

      assert_difference -> { SecurityAuditEvent.where(outcome: "denied").count }, 1 do
        assert_raises(Authorization::RestrictedVesselPolicy::AccessDenied) do
          VesselAccessInformation::Persistence.save!(
            vessel:,
            restricted_details: synthetic_secret,
            actor:,
            request_id: "denied-restricted-write-#{index}"
          )
        end
      end

      event = SecurityAuditEvent.order(:id).last
      assert_equal "vessel_access_information.write_denied", event.action
      assert_equal vessel.account, event.account
      assert_equal "Asset", event.target_type
      assert_equal vessel.id, event.target_id
      assert_empty event.changed_fields
      assert_nil event.source_ip
      assert_not_includes event.attributes.to_json, synthetic_secret
      assert_equal 0, VesselAccessInformation.count
    end
  end

  test "qualified self managed editor uses the same mutation boundary" do
    qualify_self_managed_subscription(@self_managed_account)
    owner = create_user(email: "qualified-persistence-owner@example.test", role: "owner")
    create_account_membership(user: owner, account: @self_managed_account, access_level: "editor")

    record = VesselAccessInformation::Persistence.save!(
      vessel: @self_managed_vessel,
      restricted_details: "Synthetic qualified owner value",
      actor: owner
    )

    assert record.persisted?
    assert_equal @self_managed_vessel, record.vessel
  end
end
