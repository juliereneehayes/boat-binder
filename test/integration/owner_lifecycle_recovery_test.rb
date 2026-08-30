require "test_helper"

class OwnerLifecycleRecoveryIntegrationTest < ActionDispatch::IntegrationTest
  setup do
    @now = Time.zone.local(2026, 8, 29, 12)
    @account = create_account(name: "Owner Recovery Account")
    @owner = create_user(email: "owner-recovery@example.test", role: "owner")
    @membership = create_account_membership(user: @owner, account: @account, access_level: "editor")
    @vessel = create_vessel(account: @account, name: "Private Recovery Vessel")
    @document = @vessel.documents.create!(
      account: @account,
      title: "Private Recovery Document",
      document_type: "other"
    )
    @note = @vessel.binder_notes.create!(
      account: @account,
      title: "Private Recovery Note",
      body: "Sensitive recovery note body",
      note_type: "general"
    )
    @previous_monthly_price = Rails.configuration.x.stripe.self_managed_monthly_price_id
    @previous_annual_price = Rails.configuration.x.stripe.self_managed_annual_price_id
    Rails.configuration.x.stripe.self_managed_monthly_price_id = "price_recovery_monthly"
    Rails.configuration.x.stripe.self_managed_annual_price_id = "price_recovery_annual"
    sign_in_as @owner
  end

  teardown do
    Rails.configuration.x.stripe.self_managed_monthly_price_id = @previous_monthly_price
    Rails.configuration.x.stripe.self_managed_annual_price_id = @previous_annual_price
  end

  test "current entitlement keeps the ordinary dashboard free of recovery warnings" do
    configure_subscription(status: "active", current_period_ends_at: @now + 1.month)

    travel_to @now do
      without_stripe_calls do
        get root_path
      end
    end

    assert_response :success
    assert_includes response.body, @vessel.name
    assert_not_includes response.body, "Account recovery options"
    assert_not_includes response.body, "Request an account export"
  end

  test "canonical cancel at shows exact paid through recovery while preserving writes until the boundary" do
    cancel_at = @now + 2.weeks
    configure_subscription(
      status: "active",
      current_period_ends_at: @now + 1.month,
      cancel_at:
    )

    travel_to @now do
      without_stripe_calls { get root_path }

      patch vessel_path(@vessel), params: { asset: { name: "Scheduled Access Vessel" } }
    end

    assert_redirected_to vessel_path(@vessel.reload)
    assert_equal "Scheduled Access Vessel", @vessel.name

    travel_to @now do
      get root_path
      assert_response :success
      assert_includes response.body, "Your plan is scheduled to end"
      assert_includes response.body, "Paid through"
      assert_includes response.body, "Sep 12, 2026 at 12:00 PM PDT"
      assert_select "form[action=?]", billing_portal_path, count: 1
      assert_select "form[action=?]", account_export_requests_path, count: 1
      assert_select "form[action=?]", billing_reactivation_path, count: 0
    end
  end

  test "clearing canonical cancel at removes recovery actions and keeps current access" do
    configure_subscription(
      status: "active",
      current_period_ends_at: @now + 1.month,
      cancel_at: @now + 2.weeks
    )
    @account.subscription.update!(cancel_at: nil)

    travel_to(@now) { get root_path }

    assert_response :success
    assert_includes response.body, @vessel.name
    assert_not_includes response.body, "Your plan is scheduled to end"
    assert_select "form[action=?]", account_export_requests_path, count: 0
  end

  test "payment recovery preserves reads and offers supported recovery actions" do
    configure_subscription(status: "past_due")

    travel_to(@now) { get root_path }

    assert_response :success
    assert_includes response.body, "Please update your billing details"
    assert_includes response.body, @vessel.name
    assert_select "form[action=?]", billing_portal_path, count: 1
    assert_select "form[action=?]", account_export_requests_path, count: 1
    assert_select "form[action=?]", billing_reactivation_path, count: 0
  end

  test "read only grace shows records and verified terminal reactivation choices" do
    configure_subscription(status: "canceled", entitlement_ended_at: @now - 1.day)

    travel_to(@now) { get root_path }

    assert_response :success
    assert_includes response.body, "Your binder is read-only"
    assert_includes response.body, @vessel.name
    assert_select "form[action=?]", billing_reactivation_path, count: 2
    assert_select "input[name=option_key][value=self_managed_monthly]", count: 1
    assert_select "input[name=option_key][value=self_managed_annual]", count: 1
    assert_select "form[action=?]", account_export_requests_path, count: 1
  end

  test "retained and archive recovery surfaces minimize protected data" do
    [
      [ @now - 4.months, "Your binder is currently unavailable" ],
      [ @now - 13.months, "Your binder may need support to restore" ]
    ].each do |ended_at, expected_title|
      configure_subscription(status: "canceled", entitlement_ended_at: ended_at)

      travel_to(@now) { get root_path }

      assert_response :success
      assert_includes response.body, expected_title
      assert_includes response.body, @account.name
      assert_not_includes response.body, @vessel.name
      assert_not_includes response.body, @document.title
      assert_not_includes response.body, @note.title
      assert_not_includes response.body, @note.body
      assert_select "a[href*='/rails/active_storage']", count: 0
      assert_select "form[action=?]", billing_reactivation_path, count: 2
      assert_select "form[action=?]", account_export_requests_path, count: 1
    end
  end

  test "manual review offers no billing reactivation or export action" do
    configure_subscription(status: "suspended", entitlement_ended_at: @now - 1.day)

    travel_to(@now) { get root_path }

    assert_response :success
    assert_includes response.body, "Your account needs review"
    assert_select "form[action=?]", billing_portal_path, count: 0
    assert_select "form[action=?]", billing_reactivation_path, count: 0
    assert_select "form[action=?]", account_export_requests_path, count: 0
  end

  test "read only Owner can request approved phase export but cannot use billing actions" do
    @membership.update!(access_level: "read_only")
    configure_subscription(status: "canceled", entitlement_ended_at: @now - 4.months)

    travel_to(@now) { get root_path }

    assert_response :success
    assert_select "form[action=?]", account_export_requests_path, count: 1
    assert_select "form[action=?]", billing_portal_path, count: 0
    assert_select "form[action=?]", billing_reactivation_path, count: 0

    assert_difference -> { AccountExportRequest.count }, 1 do
      post account_export_requests_path, params: {
        account_reference: Billing::OwnerAccountReference.generate(@account)
      }
    end
    assert_redirected_to root_path
    assert_equal "retained_inactive", AccountExportRequest.last.lifecycle_context
  end

  test "tampered cross Account and inactive membership requests fail closed" do
    configure_subscription(status: "canceled", entitlement_ended_at: @now - 4.months)
    other_account = create_account(name: "Unrelated Export Account")
    other_owner = create_user(email: "unrelated-export@example.test", role: "owner")
    create_account_membership(user: other_owner, account: other_account, access_level: "editor")

    [
      Billing::OwnerAccountReference.generate(other_account),
      "tampered-account-reference"
    ].each do |reference|
      assert_no_difference -> { AccountExportRequest.count } do
        post account_export_requests_path, params: { account_reference: reference }
      end
      assert_access_denied_redirect
    end

    @membership.update!(active: false)
    assert_no_difference -> { AccountExportRequest.count } do
      post account_export_requests_path, params: {
        account_reference: Billing::OwnerAccountReference.generate(@account)
      }
    end
    assert_access_denied_redirect
  end

  test "direct export requests are denied outside approved lifecycle contexts" do
    reference = Billing::OwnerAccountReference.generate(@account)

    configure_subscription(status: "active", current_period_ends_at: @now + 1.month)
    assert_no_difference -> { AccountExportRequest.count } do
      post account_export_requests_path, params: { account_reference: reference }
    end
    assert_access_denied_redirect

    configure_subscription(status: "suspended", entitlement_ended_at: @now - 1.day)
    assert_no_difference -> { AccountExportRequest.count } do
      post account_export_requests_path, params: { account_reference: reference }
    end
    assert_access_denied_redirect
  end

  test "duplicate and replayed export requests create only one open audit record" do
    configure_subscription(status: "canceled", entitlement_ended_at: @now - 4.months)
    params = { account_reference: Billing::OwnerAccountReference.generate(@account) }

    assert_difference -> { AccountExportRequest.count }, 1 do
      post account_export_requests_path, params:
    end
    assert_redirected_to root_path

    assert_no_difference -> { AccountExportRequest.count } do
      post account_export_requests_path, params:
    end
    assert_redirected_to root_path
    follow_redirect!
    assert_includes response.body, AccountExportRequestsController::DUPLICATE_MESSAGE
  end

  test "non owner users cannot submit export requests" do
    admin = create_user(email: "export-admin-denied@example.test", role: "admin")
    sign_in_as admin

    assert_no_difference -> { AccountExportRequest.count } do
      post account_export_requests_path, params: {
        account_reference: Billing::OwnerAccountReference.generate(@account)
      }
    end
    assert_access_denied_redirect
  end

  private

  def configure_subscription(status:, current_period_ends_at: nil, entitlement_ended_at: nil,
    cancel_at_period_end: false, cancel_at: nil)
    @account.subscription.update!(
      provider: Subscription::STRIPE_PROVIDER,
      plan: "self_managed",
      status:,
      external_customer_id: "cus_owner_recovery",
      external_subscription_id: "sub_owner_recovery",
      current_period_ends_at:,
      entitlement_ended_at:,
      cancel_at_period_end:,
      cancel_at:,
      last_synced_at: @now - 1.minute
    )
  end

  def without_stripe_calls
    original_subscription_retrieve = Stripe::Subscription.method(:retrieve)
    original_portal_create = Stripe::BillingPortal::Session.method(:create)
    Stripe::Subscription.define_singleton_method(:retrieve) { |*| raise "rendering called Stripe" }
    Stripe::BillingPortal::Session.define_singleton_method(:create) { |*| raise "rendering called Stripe" }
    yield
  ensure
    Stripe::Subscription.define_singleton_method(:retrieve, original_subscription_retrieve)
    Stripe::BillingPortal::Session.define_singleton_method(:create, original_portal_create)
  end
end
