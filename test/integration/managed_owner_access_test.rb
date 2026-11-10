require "test_helper"

class ManagedOwnerAccessTest < ActionDispatch::IntegrationTest
  setup do
    @account = create_account(name: "Managed Owner")
    @vessel = create_vessel(account: @account)
    @owner = create_user(email: "managed-owner@example.test", role: "owner")
    @membership = create_account_membership(user: @owner, account: @account, access_level: "editor")
    @admin = create_user(email: "managed-admin@example.test", role: "admin")
    @relationship = ManagedServiceRelationship::Transition.call!(account: @account, active: true, actor: @admin)
  end

  test "Admin enrollment is audited idempotent and leaves billing unchanged" do
    sign_in_as @admin
    subscription = @account.subscription.attributes
    get owner_path(@account)
    assert_select "button", text: "Revoke HYC Managed Service"
    assert_difference -> { SecurityAuditEvent.where(action: "managed_service_relationship.revoked").count }, 1 do
      2.times { post revoke_managed_service_owner_path(@account) }
    end
    assert_not @relationship.reload.active?
    assert_difference -> { SecurityAuditEvent.where(action: "managed_service_relationship.activated").count }, 1 do
      2.times { post activate_managed_service_owner_path(@account) }
    end
    assert @relationship.reload.active?
    assert_equal subscription, @account.subscription.reload.attributes
    assert_equal @admin, SecurityAuditEvent.where(action: "managed_service_relationship.activated").last.actor_user
  end

  test "Captain and Owner cannot enroll through direct requests" do
    [ @owner, create_user(email: "managed-captain@example.test") ].each do |user|
      sign_in_as user
      if user.captain?
        get owner_path(@account)
        assert_response :success
        assert_select "button", text: "Revoke HYC Managed Service", count: 0
      end
      assert_no_difference -> { SecurityAuditEvent.where(action: "managed_service_relationship.revoked").count } do
        post revoke_managed_service_owner_path(@account)
        assert_redirected_to root_path
        post activate_managed_service_owner_path(@account)
        assert_redirected_to root_path
      end
      assert @relationship.reload.active?
    end
  end

  test "active subscription blocks enrollment without changing billing" do
    ManagedServiceRelationship::Transition.call!(account: @account, active: false, actor: @admin)
    qualify_self_managed_subscription(@account)
    original = @account.subscription.reload.attributes
    sign_in_as @admin
    post activate_managed_service_owner_path(@account)
    assert_redirected_to owner_path(@account)
    assert_match "Review the existing Self Managed subscription", flash[:alert]
    assert_not @relationship.reload.active?
    assert_equal original, @account.subscription.reload.attributes
  end

  test "active checkout blocks activation and internal Accounts cannot enroll" do
    @relationship.update!(active: false)
    @account.billing_checkout_attempts.create!(option_key: "self_managed_monthly", status: "creating", stripe_customer_id: "cus_synthetic", idempotency_key: SecureRandom.uuid)
    assert_raises(ManagedServiceRelationship::Transition::EnrollmentError) do
      ManagedServiceRelationship::Transition.call!(account: @account, active: true, actor: @admin)
    end
    internal_account = create_account(name: "Internal", account_type: "internal")
    assert_raises(ManagedServiceRelationship::Transition::EnrollmentError) do
      ManagedServiceRelationship::Transition.call!(account: internal_account, active: true, actor: @admin)
    end
  end

  test "managed access needs no subscription and bypasses recovery and checkout" do
    @account.subscription.destroy!
    sign_in_as @owner
    get root_path
    assert_response :success
    assert_not_includes response.body, "Account review needed"
    get vessel_path(@vessel)
    assert_response :success
    get billing_checkout_path
    assert_redirected_to root_path
    post billing_checkout_path, params: { option_key: "self_managed_monthly" }
    assert_redirected_to root_path
    recovery = Billing::OwnerLifecycleRecovery.new(account: @account.reload, membership: @membership)
    assert_not recovery.visible?
    assert Authorization::RestrictedVesselPolicy.new(user: @owner).writable?(@vessel)
  end

  test "managed editor uses existing vessels visits notes and reminders" do
    sign_in_as @owner
    assert_difference -> { Asset.vessels.count } do
      post vessels_path, params: { asset: { name: "Second managed vessel" } }
    end
    patch vessel_path(@vessel), params: { asset: { name: "Updated vessel" } }
    assert_equal "Updated vessel", @vessel.reload.name
    post vessel_service_visits_path(@vessel), params: { service_visit: { visit_date: Date.current, summary: "Owner visit", follow_up_needed: true } }
    visit = @vessel.service_visits.last
    assert_equal "owner", visit.author_kind
    patch vessel_service_visit_path(@vessel, visit), params: { service_visit: { summary: "Updated visit" } }
    assert_equal "Updated visit", visit.reload.summary
    patch complete_follow_up_vessel_service_visit_path(@vessel, visit)
    assert visit.reload.follow_up_completed_at
    patch reopen_follow_up_vessel_service_visit_path(@vessel, visit)
    assert_nil visit.reload.follow_up_completed_at
    post vessel_binder_notes_path(@vessel), params: { binder_note: { title: "Owner note", body: "Synthetic", note_type: "general" } }
    note = @vessel.binder_notes.last
    patch vessel_binder_note_path(@vessel, note), params: { binder_note: { title: "Edited note" } }
    assert_equal "Edited note", note.reload.title
    post reminders_path, params: { reminder: { asset_id: @vessel.id, title: "Owner reminder", due_date: Date.tomorrow, reminder_type: "maintenance" } }
    reminder = @vessel.reminders.last
    patch reminder_path(reminder), params: { status_action: "complete" }
    assert_equal "completed", reminder.reload.status
  end

  test "professional and historical visits reject all Owner mutations" do
    professional = @vessel.service_visits.create!(performed_by_user: @admin, visit_date: Date.current, summary: "Professional", follow_up_needed: true)
    unknown = @vessel.service_visits.create!(performed_by_user: @owner, visit_date: Date.current, summary: "Historical", follow_up_needed: true)
    unknown.update_column(:author_kind, nil)
    sign_in_as @owner
    [ professional, unknown ].each do |visit|
      get vessel_service_visit_path(@vessel, visit)
      assert_response :success
      get edit_vessel_service_visit_path(@vessel, visit)
      assert_redirected_to root_path
      patch vessel_service_visit_path(@vessel, visit), params: { service_visit: { summary: "Blocked" } }
      assert_redirected_to root_path
      patch complete_follow_up_vessel_service_visit_path(@vessel, visit)
      assert_redirected_to root_path
      patch reopen_follow_up_vessel_service_visit_path(@vessel, visit)
      assert_redirected_to root_path
      assert_not_equal "Blocked", visit.reload.summary
      assert_nil visit.follow_up_completed_at
    end
  end

  test "inactive states and revoked relationship fail closed with valid Self Managed fallback" do
    sign_in_as @owner
    [ @membership, @account, @relationship ].each do |record|
      record.update!(active: false)
      get vessel_path(@vessel)
      assert_response :not_found
      assert_not Authorization::RestrictedVesselPolicy.new(user: @owner.reload).readable?(@vessel.reload)
      record.update!(active: true)
    end
    @owner.update!(active: false)
    assert_empty Authorization::SelfManagedOwnerPolicy.new(user: @owner.reload).readable_account_ids
    @owner.update!(active: true)
    @relationship.update!(active: false)
    qualify_self_managed_subscription(@account)
    sign_in_as @owner
    patch vessel_path(@vessel), params: { asset: { name: "Independent access" } }
    assert_equal "Independent access", @vessel.reload.name
  end

  test "read only access and mixed Accounts preserve isolation" do
    other = create_account(name: "Unentitled")
    other_vessel = create_vessel(account: other, name: "Unentitled vessel")
    create_account_membership(user: @owner, account: other, access_level: "editor")
    sign_in_as @owner
    get vessel_path(other_vessel)
    assert_response :not_found
    @membership.update!(access_level: "read_only")
    get vessel_path(@vessel)
    assert_response :success
    patch vessel_path(@vessel), params: { asset: { name: "Denied" } }
    assert_redirected_to root_path
    post vessel_binder_notes_path(@vessel), params: { binder_note: { title: "Denied", note_type: "general" } }
    assert_redirected_to root_path
    assert_not Authorization::RestrictedVesselPolicy.new(user: @owner).writable?(@vessel)
  end

  test "managed Account reuses the Owner limit for membership and role changes" do
    second = create_user(email: "second-managed@example.test", role: "owner")
    blocked = @account.account_memberships.new(user: second, active: true, access_level: "editor")
    assert_not blocked.save
    captain = create_user(email: "role-managed@example.test")
    create_account_membership(user: captain, account: @account)
    assert_not captain.update(role: "owner")
    @relationship.update!(active: false)
    create_account_membership(user: second, account: @account)
    assert_raises(ManagedServiceRelationship::Transition::EnrollmentError) do
      ManagedServiceRelationship::Transition.call!(account: @account, active: true, actor: @admin)
    end
  end
end
