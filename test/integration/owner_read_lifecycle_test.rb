require "test_helper"

class OwnerReadLifecycleTest < ActionDispatch::IntegrationTest
  BOUNDARY_DELTA = Rational(1, 1_000_000)

  setup do
    @now = Time.zone.local(2026, 8, 24, 12)
    @account = create_account(name: "Lifecycle Owner")
    @vessel = create_vessel(account: @account, name: "Lifecycle Vessel")
    @vessel.primary_photo.attach(fixture_file_upload("sample.jpg", "image/jpeg"))
    @document = @vessel.documents.create!(
      account: @account,
      title: "Lifecycle Registration",
      document_type: "registration"
    )
    @document.file.attach(fixture_file_upload("sample.pdf", "application/pdf"))
    @reminder = @vessel.reminders.create!(
      title: "Lifecycle Reminder",
      due_date: @now.to_date + 1.week,
      reminder_type: "maintenance",
      status: "pending"
    )
    @captain = create_user(email: "lifecycle-captain@example.test", role: "captain")
    @visit = @vessel.service_visits.create!(
      performed_by_user: @captain,
      visit_date: @now.to_date,
      summary: "Lifecycle Visit"
    )
    @visit.photos.attach(fixture_file_upload("sample.png", "image/png"))
    @note = @vessel.binder_notes.create!(
      account: @account,
      title: "Lifecycle Note",
      body: "Protected owner note",
      note_type: "general"
    )
    @owner = create_user(email: "lifecycle-owner@example.test", role: "owner")
    @membership = create_account_membership(
      user: @owner,
      account: @account,
      access_level: "editor"
    )
  end

  test "current entitlement permits scoped owner reads and preserves membership based writes" do
    configure_current_entitlement
    sign_in_as @owner

    travel_to @now do
      without_stripe_subscription_retrieval do
        assert_owner_read_paths_available

        patch vessel_path(@vessel), params: { asset: { name: "Current Vessel" } }
        assert_redirected_to vessel_path(@vessel.reload)
        assert_equal "Current Vessel", @vessel.name
      end
    end

    read_only_owner = create_user(email: "lifecycle-read-only@example.test", role: "owner")
    create_account_membership(user: read_only_owner, account: @account, access_level: "read_only")
    sign_in_as read_only_owner

    patch vessel_path(@vessel), params: { asset: { name: "Blocked Read Only Update" } }
    assert_access_denied_redirect
    assert_equal "Current Vessel", @vessel.reload.name
  end

  test "read only grace preserves reads at entitlement end and immediately before ninety days" do
    ended_at = @now
    configure_ended_entitlement(ended_at:)
    sign_in_as @owner

    [ ended_at, ended_at + 90.days - BOUNDARY_DELTA ].each do |evaluation_time|
      travel_to evaluation_time do
        assert_owner_read_paths_available

        patch vessel_path(@vessel), params: { asset: { name: "Blocked Grace Update" } }
        assert_access_denied_redirect
        assert_equal "Lifecycle Vessel", @vessel.reload.name
      end
    end
  end

  test "retained inactive phase denies reads at ninety days without changing records or attachments" do
    ended_at = @now
    configure_ended_entitlement(ended_at:)
    sign_in_as @owner
    original_state = persisted_state

    [ ended_at + 90.days, ended_at + 90.days + 1.second ].each do |evaluation_time|
      travel_to evaluation_time do
        assert_restricted_owner_state
      end
    end

    assert_equal original_state, persisted_state
  end

  test "archive eligible phase remains restricted without archiving or deleting data" do
    ended_at = @now
    configure_ended_entitlement(ended_at:)
    sign_in_as @owner
    original_state = persisted_state

    [ ended_at + 12.months, ended_at + 12.months + 1.second ].each do |evaluation_time|
      travel_to evaluation_time do
        assert_restricted_owner_state
      end
    end

    assert_equal original_state, persisted_state
  end

  test "verified reactivation restores the same records and existing editor write eligibility" do
    ended_at = @now - 4.months
    configure_ended_entitlement(ended_at:)
    account_id = @account.id
    subscription_id = @account.subscription.id
    membership_id = @membership.id
    original_state = persisted_state
    sign_in_as @owner

    travel_to @now do
      get root_path
      assert_restricted_dashboard

      configure_current_entitlement
      get root_path
      assert_response :success
      assert_includes response.body, @vessel.name

      patch vessel_path(@vessel), params: { asset: { name: "Reactivated Vessel" } }
      assert_redirected_to vessel_path(@vessel.reload)
    end

    assert_equal account_id, @account.reload.id
    assert_equal subscription_id, @account.subscription.id
    assert_equal membership_id, @membership.reload.id
    assert_equal(
      original_state.except(:vessel_name, :lifecycle_timestamps),
      persisted_state.except(:vessel_name, :lifecycle_timestamps)
    )
    assert_equal "Reactivated Vessel", @vessel.reload.name
    assert_equal ended_at, @account.subscription.entitlement_ended_at
    assert_equal 1, Subscription.where(account: @account).count
  end

  test "payment recovery pending preserves reads but manual review does not" do
    configure_verified_subscription(status: "past_due")
    sign_in_as @owner

    travel_to @now do
      get vessel_path(@vessel)
      assert_response :success
      assert_includes response.body, @document.title

      patch vessel_path(@vessel), params: { asset: { name: "Blocked Past Due Update" } }
      assert_access_denied_redirect
      assert_equal "Lifecycle Vessel", @vessel.reload.name

      @account.subscription.update!(status: "suspended", entitlement_ended_at: @now - 1.day)
      get root_path
      assert_restricted_dashboard

      get vessel_path(@vessel)
      assert_response :not_found
    end
  end

  test "local missing and unsupported lifecycle states fail closed" do
    sign_in_as @owner

    get root_path
    assert_restricted_dashboard

    @account.subscription.destroy!
    get root_path
    assert_restricted_dashboard

    with_lifecycle_phase(:future_phase) do
      get root_path
      assert_restricted_dashboard
      get vessel_path(@vessel)
      assert_response :not_found
    end
  end

  test "active Local Legacy subscription denies owner binder reads" do
    @account.subscription.update!(
      provider: Subscription::LOCAL_PROVIDER,
      plan: "legacy",
      status: "active"
    )

    assert_unsupported_plan_owner_is_restricted
  end

  test "active Stripe Starter subscription denies owner binder reads" do
    configure_current_entitlement
    @account.subscription.update!(plan: "starter")

    assert_unsupported_plan_owner_is_restricted
  end

  test "active Stripe Professional subscription denies owner binder reads" do
    configure_current_entitlement
    @account.subscription.update!(plan: "professional")

    assert_unsupported_plan_owner_is_restricted
  end

  test "mixed memberships expose only records and counts from readable accounts" do
    configure_current_entitlement
    restricted_account = create_account(name: "Restricted Lifecycle Account")
    restricted_vessel = create_vessel(account: restricted_account, name: "Restricted Lifecycle Vessel")
    restricted_document = restricted_vessel.documents.create!(
      account: restricted_account,
      title: "Restricted Lifecycle Document",
      document_type: "other"
    )
    restricted_visit = restricted_vessel.service_visits.create!(
      performed_by_user: @captain,
      visit_date: @now.to_date,
      summary: "Restricted Lifecycle Visit"
    )
    create_account_membership(user: @owner, account: restricted_account, access_level: "editor")
    configure_ended_entitlement(account: restricted_account, ended_at: @now - 4.months)
    sign_in_as @owner

    travel_to @now do
      get root_path
      assert_response :success
      assert_includes response.body, @vessel.name
      assert_not_includes response.body, restricted_account.name
      assert_not_includes response.body, restricted_vessel.name
      assert_not_includes response.body, restricted_document.title
      assert_not_includes response.body, restricted_visit.summary
      assert_match(/Active vessels.*?>1</m, response.body)

      get vessels_path
      assert_response :success
      assert_includes response.body, @vessel.name
      assert_not_includes response.body, restricted_vessel.name

      get vessel_path(restricted_vessel)
      assert_response :not_found
      get document_path(restricted_document)
      assert_response :not_found
      get vessel_service_visit_path(restricted_vessel, restricted_visit)
      assert_response :not_found
    end
  end

  test "inactive memberships and accounts grant no owner reads while internal access remains independent" do
    configure_current_entitlement
    @membership.update!(active: false)
    sign_in_as @owner

    get vessel_path(@vessel)
    assert_response :not_found
    get root_path
    assert_response :success
    assert_not_includes response.body, @vessel.name

    @membership.update!(active: true)
    @account.update!(active: false)
    get vessel_path(@vessel)
    assert_response :not_found
    get root_path
    assert_response :success
    assert_not_includes response.body, @vessel.name

    sign_in_as @captain
    get vessel_path(@vessel)
    assert_response :success
    assert_includes response.body, @vessel.name
    get document_path(@document)
    assert_response :success
    get report_vessel_service_visit_path(@vessel, @visit)
    assert_response :success
  end

  test "internal users retain binder reads across representative restricted lifecycle states" do
    sign_in_as @captain

    restricted_configurations = [
      -> { @account.subscription.update!(Subscription.default_local_attributes) },
      -> { configure_verified_subscription(status: "suspended", entitlement_ended_at: @now - 1.day) },
      -> { configure_ended_entitlement(ended_at: @now - 4.months) },
      -> { @account.subscription.destroy! },
      -> {
        @account.create_subscription!(Subscription.default_local_attributes) unless @account.reload.subscription
        configure_current_entitlement
        @account.update!(active: false)
      }
    ]

    restricted_configurations.each do |configure|
      @account.update!(active: true)
      @account.create_subscription!(Subscription.default_local_attributes) unless @account.reload.subscription
      configure.call

      get vessel_path(@vessel)
      assert_response :success
      assert_includes response.body, @vessel.name
      get document_path(@document)
      assert_response :success
      get report_vessel_service_visit_path(@vessel, @visit)
      assert_response :success
    end
  end

  test "owner read authorization performs no Stripe request and mutates no persisted lifecycle data" do
    configure_current_entitlement
    sign_in_as @owner
    original_state = persisted_state

    travel_to @now do
      without_stripe_subscription_retrieval do
        get root_path
        assert_response :success
        get vessel_path(@vessel)
        assert_response :success
        get document_path(@document)
        assert_response :success
      end
    end

    assert_equal original_state, persisted_state
  end

  private

  def assert_owner_read_paths_available
    get root_path
    assert_response :success
    assert_includes response.body, @vessel.name

    get vessels_path
    assert_response :success
    assert_includes response.body, @vessel.name
    get vessel_path(@vessel)
    assert_response :success
    assert_includes response.body, @note.title
    assert_select "#documents a[href^='/rails/active_storage']", minimum: 1

    get documents_path
    assert_response :success
    assert_includes response.body, @document.title
    assert_select "a[href^='/rails/active_storage']", minimum: 1
    get document_path(@document)
    assert_response :success
    assert_select "a[href^='/rails/active_storage']", minimum: 1

    get reminders_path
    assert_response :success
    assert_includes response.body, @reminder.title
    get service_visits_path
    assert_response :success
    assert_includes response.body, @visit.summary
    get vessel_service_visit_path(@vessel, @visit)
    assert_response :success
    get report_vessel_service_visit_path(@vessel, @visit)
    assert_response :success
  end

  def assert_restricted_owner_state
    get root_path
    assert_restricted_dashboard

    [ vessels_path, documents_path, reminders_path, service_visits_path,
      vessel_service_visits_path(@vessel) ].each do |path|
      get path
      assert_access_denied_redirect
    end

    [ vessel_path(@vessel), document_path(@document),
      vessel_service_visit_path(@vessel, @visit),
      report_vessel_service_visit_path(@vessel, @visit) ].each do |path|
      get path
      assert_response :not_found
    end

    patch vessel_path(@vessel), params: { asset: { name: "Blocked Restricted Update" } }
    assert_response :not_found
    assert_equal "Lifecycle Vessel", @vessel.reload.name
  end

  def assert_restricted_dashboard
    assert_response :success
    assert_includes response.body, "Your binder is not available right now."
    assert_not_includes response.body, @account.name
    assert_not_includes response.body, @vessel.name
    assert_not_includes response.body, @document.title
    assert_not_includes response.body, @reminder.title
    assert_not_includes response.body, @note.body
    assert_not_includes response.body, @visit.summary
    assert_not_includes response.body, "Active vessels"
    assert_select "a[href=?]", vessels_path, count: 0
    assert_select "a[href=?]", documents_path, count: 0
    assert_select "a[href=?]", service_visits_path, count: 0
    assert_select "a[href*='/rails/active_storage']", count: 0
    assert_select "img[src*='/rails/active_storage']", count: 0
    assert_select "form[action=?]", session_path, minimum: 1
    assert_select "a[href=?]", billing_checkout_path, text: "View Self Managed plans", count: 1
  end

  def assert_unsupported_plan_owner_is_restricted
    sign_in_as @owner
    assert_redirected_to root_path
    original_state = persisted_state

    travel_to @now do
      assert_restricted_owner_state
    end

    assert_equal original_state, persisted_state
  end

  def configure_current_entitlement(account: @account)
    configure_verified_subscription(account:, status: "active", current_period_ends_at: @now + 1.month)
  end

  def configure_ended_entitlement(account: @account, ended_at:)
    configure_verified_subscription(
      account:,
      status: "canceled",
      current_period_ends_at: nil,
      entitlement_ended_at: ended_at
    )
  end

  def configure_verified_subscription(account: @account, status:, current_period_ends_at: @now + 1.month,
    entitlement_ended_at: :preserve)
    attributes = {
      provider: Subscription::STRIPE_PROVIDER,
      plan: "self_managed",
      status:,
      external_customer_id: "cus_#{account.id}",
      external_subscription_id: "sub_#{account.id}",
      trial_ends_at: @now + 7.days,
      current_period_ends_at:,
      cancel_at_period_end: false,
      last_synced_at: @now - 1.minute
    }
    attributes[:entitlement_ended_at] = entitlement_ended_at unless entitlement_ended_at == :preserve
    account.subscription.update!(attributes)
  end

  def persisted_state
    {
      account_ids: Account.where(id: @account.id).pluck(:id),
      subscription_ids: Subscription.where(account: @account).pluck(:id),
      membership_ids: AccountMembership.where(id: @membership.id).pluck(:id),
      vessel_name: @vessel.reload.name,
      document_ids: Document.where(id: @document.id).pluck(:id),
      reminder_ids: Reminder.where(id: @reminder.id).pluck(:id),
      visit_ids: ServiceVisit.where(id: @visit.id).pluck(:id),
      note_ids: BinderNote.where(id: @note.id).pluck(:id),
      attachment_ids: ActiveStorage::Attachment.where(record: [ @vessel, @document, @visit ]).order(:id).pluck(:id),
      blob_ids: ActiveStorage::Blob.order(:id).pluck(:id),
      lifecycle_timestamps: @account.subscription.attributes.slice(
        "trial_ends_at",
        "current_period_ends_at",
        "entitlement_ended_at",
        "past_due_observed_at",
        "last_synced_at"
      )
    }
  end

  def without_stripe_subscription_retrieval
    original_retrieve = Stripe::Subscription.method(:retrieve)
    Stripe::Subscription.define_singleton_method(:retrieve) do |*|
      raise "Owner read authorization called Stripe"
    end
    yield
  ensure
    Stripe::Subscription.define_singleton_method(:retrieve, original_retrieve)
  end

  def with_lifecycle_phase(phase)
    original_method = Billing::SelfManagedEntitlement.instance_method(:lifecycle_phase)
    Billing::SelfManagedEntitlement.define_method(:lifecycle_phase) { phase }
    yield
  ensure
    Billing::SelfManagedEntitlement.define_method(:lifecycle_phase, original_method)
  end
end
