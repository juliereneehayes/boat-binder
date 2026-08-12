require "test_helper"

class StripeWebhookTest < ActionDispatch::IntegrationTest
  WEBHOOK_SECRET = "whsec_test_secret"

  setup do
    @previous_webhook_secret = Rails.configuration.x.stripe.webhook_secret
    @previous_monthly_price_id = Rails.configuration.x.stripe.self_managed_monthly_price_id
    @previous_annual_price_id = Rails.configuration.x.stripe.self_managed_annual_price_id
    Rails.configuration.x.stripe.webhook_secret = WEBHOOK_SECRET
    Rails.configuration.x.stripe.self_managed_monthly_price_id = "price_webhook_monthly"
    Rails.configuration.x.stripe.self_managed_annual_price_id = "price_webhook_annual"
  end

  teardown do
    Rails.configuration.x.stripe.webhook_secret = @previous_webhook_secret
    Rails.configuration.x.stripe.self_managed_monthly_price_id = @previous_monthly_price_id
    Rails.configuration.x.stripe.self_managed_annual_price_id = @previous_annual_price_id
  end

  test "test environment initializes without real Stripe credentials" do
    assert_nothing_raised do
      Billing::StripeConfiguration.secret_key
      Billing::StripeConfiguration.publishable_key
      Billing::StripeConfiguration.webhook_secret
    end
  end

  test "webhook route accepts post without authentication and rejects get" do
    assert_recognizes(
      { controller: "webhooks/stripe", action: "create" },
      { path: "/webhooks/stripe", method: :post }
    )

    assert_difference -> { BillingWebhookEvent.count }, 1 do
      post_signed_event(event_id: "evt_route_post")
    end
    assert_response :success

    get webhooks_stripe_path
    assert_response :not_found
  end

  test "webhook endpoint is not exposed in user navigation" do
    user = create_user(email: "stripe-nav-admin@example.test", role: "admin")
    sign_in_as(user)

    get root_path
    assert_response :success
    assert_not_includes response.body, "/webhooks/stripe"
  end

  test "normal browser-facing posts still require csrf protection" do
    with_forgery_protection do
      post session_path, params: {
        email_address: "captain@example.test",
        password: "password"
      }
    end

    assert_response :unprocessable_entity
  end

  test "normal authenticated requests do not invoke Stripe webhook verification" do
    user = create_user(email: "stripe-normal-request@example.test", role: "admin")
    sign_in_as(user)

    with_stripe_webhook_verification_failure do
      get root_path
    end

    assert_response :success
  end

  test "only Stripe webhook controller skips csrf verification" do
    assert csrf_skipped_for_action?(Webhooks::StripeController, :create)
    assert_equal [ "create" ], csrf_skip_actions(Webhooks::StripeController)
    assert_not csrf_skipped_for_action?(SessionsController, :create)
    assert_not csrf_skipped_for_action?(VesselsController, :create)
    assert_not csrf_skipped_for_action?(Billing::CheckoutsController, :create)
  end

  test "valid signed deferred subscription event is accepted and recorded as ignored" do
    dispatched_event_ids = []

    assert_difference -> { BillingWebhookEvent.count }, 1 do
      with_processor_call_spy(dispatched_event_ids) do
        post_signed_event(
          event_id: "evt_subscription_deleted",
          event_type: "customer.subscription.deleted",
          livemode: true,
          api_version: "2026-07-01"
        )
      end
    end

    assert_response :success
    assert_equal [ "evt_subscription_deleted" ], dispatched_event_ids
    receipt = BillingWebhookEvent.find_by!(provider: "stripe", external_event_id: "evt_subscription_deleted")
    assert_equal "customer.subscription.deleted", receipt.event_type
    assert receipt.livemode?
    assert_equal "2026-07-01", receipt.api_version
    assert_equal "ignored", receipt.status
    assert receipt.processed_at.present?
  end

  test "signed Checkout and subscription events synchronize the correct trialing subscription" do
    account = create_account(name: "Webhook Checkout Owner")
    account_reference = Billing::StripeAccountReference.generate(account)
    attempt = create_checkout_attempt(
      account: account,
      customer_id: "cus_checkout_sync",
      session_id: "cs_checkout_sync"
    )
    original_status = account.subscription.status
    trial_end = 7.days.from_now.change(usec: 0)
    period_end = 1.month.from_now.change(usec: 0)

    post_signed_event(
      event_id: "evt_checkout_completed",
      event_type: "checkout.session.completed",
      data_object: checkout_session_data(
        attempt: attempt,
        account_reference: account_reference,
        customer_id: "cus_checkout_sync",
        subscription_id: "sub_checkout_sync"
      )
    )

    assert_response :success
    checkout_receipt = BillingWebhookEvent.find_by!(external_event_id: "evt_checkout_completed")
    assert_equal "processed", checkout_receipt.status
    subscription = account.subscription.reload
    assert_equal "stripe", subscription.provider
    assert_equal "cus_checkout_sync", subscription.external_customer_id
    assert_equal "sub_checkout_sync", subscription.external_subscription_id
    assert_equal original_status, subscription.status

    post_signed_event(
      event_id: "evt_subscription_created",
      event_type: "customer.subscription.created",
      data_object: subscription_data(
        attempt: attempt,
        account_reference: account_reference,
        customer_id: "cus_checkout_sync",
        subscription_id: "sub_checkout_sync",
        status: "trialing",
        trial_end: trial_end,
        period_end: period_end
      )
    )

    assert_response :success
    lifecycle_receipt = BillingWebhookEvent.find_by!(external_event_id: "evt_subscription_created")
    assert_equal "processed", lifecycle_receipt.status
    subscription.reload
    assert_equal "self_managed", subscription.plan
    assert_equal "trialing", subscription.status
    assert_equal "stripe", subscription.provider
    assert_equal "cus_checkout_sync", subscription.external_customer_id
    assert_equal "sub_checkout_sync", subscription.external_subscription_id
    assert_equal trial_end.to_i, subscription.trial_ends_at.to_i
    assert_equal period_end.to_i, subscription.current_period_ends_at.to_i
    assert subscription.last_synced_at.present?
  end

  test "disabled known option still synchronizes an already-issued Checkout Session" do
    account = create_account(name: "Disabled Checkout Option Owner")
    account_reference = Billing::StripeAccountReference.generate(account)
    assert Billing::SubscriptionPlanCatalog.new.fetch("self_managed_monthly").enabled?
    attempt = create_checkout_attempt(
      account: account,
      customer_id: "cus_disabled_checkout",
      session_id: "cs_disabled_checkout"
    )
    original_status = account.subscription.status

    with_plan_catalog(option_catalog(enabled: false)) do
      post_signed_event(
        event_id: "evt_disabled_checkout",
        event_type: "checkout.session.completed",
        data_object: checkout_session_data(
          attempt: attempt,
          account_reference: account_reference,
          customer_id: "cus_disabled_checkout",
          subscription_id: "sub_disabled_checkout"
        )
      )
    end

    assert_response :success
    assert_equal "processed", BillingWebhookEvent.find_by!(external_event_id: "evt_disabled_checkout").status
    subscription = account.subscription.reload
    assert_equal "stripe", subscription.provider
    assert_equal "cus_disabled_checkout", subscription.external_customer_id
    assert_equal "sub_disabled_checkout", subscription.external_subscription_id
    assert_equal original_status, subscription.status
    assert_equal "completed", attempt.reload.status
  end

  test "unknown Checkout option is ignored without mutating subscription state" do
    account = create_account(name: "Unknown Checkout Option Owner")
    attempt = create_checkout_attempt(
      account: account,
      customer_id: "cus_unknown_checkout_option",
      session_id: "cs_unknown_checkout_option"
    )
    original_attributes = subscription_state(account.subscription)

    log_output = capture_rails_logs do
      post_signed_event(
        event_id: "evt_unknown_checkout_option",
        event_type: "checkout.session.completed",
        data_object: checkout_session_data(
          attempt: attempt,
          account_reference: Billing::StripeAccountReference.generate(account),
          customer_id: "cus_unknown_checkout_option",
          subscription_id: "sub_unknown_checkout_option",
          option_key: "unknown_option"
        )
      )
    end

    assert_response :success
    assert_equal "ignored", BillingWebhookEvent.find_by!(external_event_id: "evt_unknown_checkout_option").status
    assert_includes log_output, "association_code=invalid_option"
    assert_equal original_attributes, subscription_state(account.subscription.reload)
    assert_equal "open", attempt.reload.status
  end

  test "disabled known Price still synchronizes an existing Stripe subscription" do
    account = create_account(name: "Disabled Subscription Price Owner")
    account_reference = Billing::StripeAccountReference.generate(account)
    assert Billing::SubscriptionPlanCatalog.new.fetch("self_managed_monthly").enabled?
    attempt = create_checkout_attempt(account: account, customer_id: "cus_disabled_price")

    with_plan_catalog(option_catalog(enabled: false)) do
      post_signed_event(
        event_id: "evt_disabled_price",
        event_type: "customer.subscription.created",
        data_object: subscription_data(
          attempt: attempt,
          account_reference: account_reference,
          customer_id: "cus_disabled_price",
          subscription_id: "sub_disabled_price",
          status: "trialing"
        )
      )
    end

    assert_response :success
    assert_equal "processed", BillingWebhookEvent.find_by!(external_event_id: "evt_disabled_price").status
    subscription = account.subscription.reload
    assert_equal "self_managed", subscription.plan
    assert_equal "trialing", subscription.status
    assert_equal "stripe", subscription.provider
    assert_equal "cus_disabled_price", subscription.external_customer_id
    assert_equal "sub_disabled_price", subscription.external_subscription_id
    assert_equal "completed", attempt.reload.status
  end

  test "unknown Stripe Price is ignored without mutating subscription state" do
    account = create_account(name: "Unknown Subscription Price Owner")
    attempt = create_checkout_attempt(account: account, customer_id: "cus_unknown_price")
    original_attributes = subscription_state(account.subscription)

    log_output = capture_rails_logs do
      post_signed_event(
        event_id: "evt_unknown_price",
        event_type: "customer.subscription.created",
        data_object: subscription_data(
          attempt: attempt,
          account_reference: Billing::StripeAccountReference.generate(account),
          customer_id: "cus_unknown_price",
          subscription_id: "sub_unknown_price",
          status: "trialing",
          price_id: "price_unknown"
        )
      )
    end

    assert_response :success
    assert_equal "ignored", BillingWebhookEvent.find_by!(external_event_id: "evt_unknown_price").status
    assert_includes log_output, "association_code=unknown_price"
    assert_equal original_attributes, subscription_state(account.subscription.reload)
    assert_equal "open", attempt.reload.status
  end

  test "disabled option does not bypass Checkout cross-account protections" do
    account = create_account(name: "Disabled Option Target Account")
    other_account = create_account(name: "Disabled Option Other Account")
    attempt = create_checkout_attempt(
      account: account,
      customer_id: "cus_disabled_cross_account",
      session_id: "cs_disabled_cross_account"
    )
    original_attributes = subscription_state(account.subscription)
    other_original_attributes = subscription_state(other_account.subscription)

    log_output = capture_rails_logs do
      with_plan_catalog(option_catalog(enabled: false)) do
        post_signed_event(
          event_id: "evt_disabled_cross_account",
          event_type: "checkout.session.completed",
          data_object: checkout_session_data(
            attempt: attempt,
            account_reference: Billing::StripeAccountReference.generate(other_account),
            customer_id: "cus_disabled_cross_account",
            subscription_id: "sub_disabled_cross_account"
          )
        )
      end
    end

    assert_response :success
    assert_equal "ignored", BillingWebhookEvent.find_by!(external_event_id: "evt_disabled_cross_account").status
    assert_includes log_output, "association_code=account_mismatch"
    assert_equal original_attributes, subscription_state(account.subscription.reload)
    assert_equal other_original_attributes, subscription_state(other_account.subscription.reload)
    assert_equal "open", attempt.reload.status
  end

  test "subscription lifecycle event can arrive before Checkout completion" do
    account = create_account(name: "Early Subscription Event Owner")
    account_reference = Billing::StripeAccountReference.generate(account)
    attempt = create_checkout_attempt(account: account, customer_id: "cus_subscription_first")

    post_signed_event(
      event_id: "evt_subscription_first",
      event_type: "customer.subscription.created",
      data_object: subscription_data(
        attempt: attempt,
        account_reference: account_reference,
        customer_id: "cus_subscription_first",
        subscription_id: "sub_subscription_first",
        status: "trialing"
      )
    )

    assert_response :success
    subscription = account.subscription.reload
    assert_equal "self_managed", subscription.plan
    assert_equal "trialing", subscription.status
    assert_equal "cus_subscription_first", subscription.external_customer_id
    assert_equal "sub_subscription_first", subscription.external_subscription_id
  end

  test "duplicate processed subscription event is acknowledged without synchronizing twice" do
    account = create_account(name: "Duplicate Subscription Event Owner")
    attempt = create_checkout_attempt(account: account, customer_id: "cus_subscription_duplicate")
    payload = stripe_event_payload(
      event_id: "evt_subscription_duplicate",
      event_type: "customer.subscription.created",
      data_object: subscription_data(
        attempt: attempt,
        account_reference: Billing::StripeAccountReference.generate(account),
        customer_id: "cus_subscription_duplicate",
        subscription_id: "sub_subscription_duplicate",
        status: "trialing"
      )
    )
    headers = stripe_signature_headers(payload)

    assert_difference -> { BillingWebhookEvent.count }, 1 do
      post webhooks_stripe_path, params: payload, headers: headers
    end
    assert_response :success
    first_synced_at = account.subscription.reload.last_synced_at

    travel 1.second do
      assert_no_difference -> { BillingWebhookEvent.count } do
        post webhooks_stripe_path, params: payload, headers: headers
      end
    end

    assert_response :success
    assert_equal first_synced_at, account.subscription.reload.last_synced_at
  end

  test "newer lifecycle event followed by an older event does not revert subscription state" do
    account = create_account(name: "Out Of Order Newer First")
    attempt = create_checkout_attempt(account: account, customer_id: "cus_newer_first")
    account_reference = Billing::StripeAccountReference.generate(account)
    newer_trial_end = 8.days.from_now.change(usec: 0)
    newer_period_end = 2.months.from_now.change(usec: 0)
    newer_canceled_at = 1.hour.ago.change(usec: 0)

    post_signed_event(
      event_id: "evt_newer_first",
      event_type: "customer.subscription.updated",
      event_created: 200,
      data_object: subscription_data(
        attempt: attempt,
        account_reference: account_reference,
        customer_id: "cus_newer_first",
        subscription_id: "sub_newer_first",
        status: "past_due",
        trial_end: newer_trial_end,
        period_end: newer_period_end,
        cancel_at_period_end: true,
        canceled_at: newer_canceled_at
      )
    )
    assert_response :success
    newer_state = subscription_state(account.subscription.reload)

    log_output = capture_rails_logs do
      post_signed_event(
        event_id: "evt_older_second",
        event_type: "customer.subscription.created",
        event_created: 100,
        data_object: subscription_data(
          attempt: attempt.reload,
          account_reference: account_reference,
          customer_id: "cus_newer_first",
          subscription_id: "sub_newer_first",
          status: "trialing",
          trial_end: 5.days.from_now,
          period_end: 1.month.from_now,
          cancel_at_period_end: false,
          canceled_at: nil
        )
      )
    end

    assert_response :success
    assert_equal newer_state, subscription_state(account.subscription.reload)
    assert_equal "ignored", BillingWebhookEvent.find_by!(external_event_id: "evt_older_second").status
    assert_includes log_output, "reason=stale_lifecycle_event"
  end

  test "older lifecycle event followed by a newer event reaches the newer final state" do
    account = create_account(name: "Out Of Order Older First")
    attempt = create_checkout_attempt(account: account, customer_id: "cus_older_first")
    account_reference = Billing::StripeAccountReference.generate(account)

    post_signed_event(
      event_id: "evt_older_first",
      event_type: "customer.subscription.created",
      event_created: 100,
      data_object: subscription_data(
        attempt: attempt,
        account_reference: account_reference,
        customer_id: "cus_older_first",
        subscription_id: "sub_older_first",
        status: "trialing"
      )
    )
    assert_response :success

    post_signed_event(
      event_id: "evt_newer_second",
      event_type: "customer.subscription.updated",
      event_created: 200,
      data_object: subscription_data(
        attempt: attempt.reload,
        account_reference: account_reference,
        customer_id: "cus_older_first",
        subscription_id: "sub_older_first",
        status: "active",
        trial_end: nil,
        period_end: 3.months.from_now
      )
    )

    assert_response :success
    subscription = account.subscription.reload
    assert_equal "active", subscription.status
    assert_nil subscription.trial_ends_at
    assert_equal 200, subscription.stripe_last_event_created_at.to_i
    assert_equal "evt_newer_second", subscription.stripe_last_event_id
    assert_equal "processed", BillingWebhookEvent.find_by!(external_event_id: "evt_newer_second").status
  end

  test "equal Stripe event timestamps use event id as a deterministic tie breaker" do
    account = create_account(name: "Equal Event Ordering")
    attempt = create_checkout_attempt(account: account, customer_id: "cus_equal_order")
    account_reference = Billing::StripeAccountReference.generate(account)

    post_signed_event(
      event_id: "evt_equal_b",
      event_type: "customer.subscription.updated",
      event_created: 300,
      data_object: subscription_data(
        attempt: attempt,
        account_reference: account_reference,
        customer_id: "cus_equal_order",
        subscription_id: "sub_equal_order",
        status: "active"
      )
    )
    assert_response :success
    applied_state = subscription_state(account.subscription.reload)

    post_signed_event(
      event_id: "evt_equal_a",
      event_type: "customer.subscription.updated",
      event_created: 300,
      data_object: subscription_data(
        attempt: attempt.reload,
        account_reference: account_reference,
        customer_id: "cus_equal_order",
        subscription_id: "sub_equal_order",
        status: "past_due",
        cancel_at_period_end: true
      )
    )

    assert_response :success
    assert_equal applied_state, subscription_state(account.subscription.reload)
    assert_equal "ignored", BillingWebhookEvent.find_by!(external_event_id: "evt_equal_a").status
  end

  test "mismatched Checkout association is ignored without mutating either account" do
    intended_account = create_account(name: "Intended Checkout Account")
    other_account = create_account(name: "Existing Stripe Customer Account")
    attempt = create_checkout_attempt(
      account: other_account,
      customer_id: "cus_other_account",
      session_id: "cs_checkout_mismatch"
    )
    intended_original = subscription_state(intended_account.subscription)
    other_original = subscription_state(other_account.subscription)

    post_signed_event(
      event_id: "evt_checkout_mismatch",
      event_type: "checkout.session.completed",
      data_object: checkout_session_data(
        attempt: attempt,
        account_reference: Billing::StripeAccountReference.generate(intended_account),
        customer_id: "cus_other_account",
        subscription_id: "sub_mismatch"
      )
    )

    assert_response :success
    receipt = BillingWebhookEvent.find_by!(external_event_id: "evt_checkout_mismatch")
    assert_equal "ignored", receipt.status
    assert_equal intended_original, subscription_state(intended_account.subscription.reload)
    assert_equal other_original, subscription_state(other_account.subscription.reload)
  end

  test "Checkout completion with an invalid signed account reference is ignored without mutation" do
    account = create_account(name: "Invalid Checkout Reference Account")
    attempt = create_checkout_attempt(
      account: account,
      customer_id: "cus_invalid_checkout_reference",
      session_id: "cs_invalid_checkout_reference"
    )
    original_attributes = subscription_state(account.subscription)

    log_output = capture_rails_logs do
      post_signed_event(
        event_id: "evt_invalid_checkout_reference",
        event_type: "checkout.session.completed",
        data_object: checkout_session_data(
          attempt: attempt,
          account_reference: "tampered-account-reference",
          customer_id: "cus_invalid_checkout_reference",
          subscription_id: "sub_invalid_checkout_reference"
        )
      )
    end

    assert_response :success
    receipt = BillingWebhookEvent.find_by!(external_event_id: "evt_invalid_checkout_reference")
    assert_equal "ignored", receipt.status
    assert_includes log_output, "association_code=invalid_account_reference"
    assert_equal original_attributes, subscription_state(account.subscription.reload)
  end

  test "Checkout completion with another account signed reference is ignored without mutation" do
    account = create_account(name: "Checkout Reference Target")
    other_account = create_account(name: "Checkout Reference Other")
    attempt = create_checkout_attempt(
      account: account,
      customer_id: "cus_wrong_checkout_reference",
      session_id: "cs_wrong_checkout_reference"
    )
    original_attributes = subscription_state(account.subscription)

    log_output = capture_rails_logs do
      post_signed_event(
        event_id: "evt_wrong_checkout_reference",
        event_type: "checkout.session.completed",
        data_object: checkout_session_data(
          attempt: attempt,
          account_reference: Billing::StripeAccountReference.generate(other_account),
          customer_id: "cus_wrong_checkout_reference",
          subscription_id: "sub_wrong_checkout_reference"
        )
      )
    end

    assert_response :success
    receipt = BillingWebhookEvent.find_by!(external_event_id: "evt_wrong_checkout_reference")
    assert_equal "ignored", receipt.status
    assert_includes log_output, "association_code=account_mismatch"
    assert_equal original_attributes, subscription_state(account.subscription.reload)
  end

  test "subscription event with an invalid signed account reference is ignored without mutation" do
    account = create_account(name: "Invalid Subscription Reference Account")
    attempt = create_checkout_attempt(account: account, customer_id: "cus_invalid_subscription_reference")
    original_attributes = subscription_state(account.subscription)

    log_output = capture_rails_logs do
      post_signed_event(
        event_id: "evt_invalid_subscription_reference",
        event_type: "customer.subscription.created",
        data_object: subscription_data(
          attempt: attempt,
          account_reference: "tampered-account-reference",
          customer_id: "cus_invalid_subscription_reference",
          subscription_id: "sub_invalid_subscription_reference",
          status: "trialing"
        )
      )
    end

    assert_response :success
    receipt = BillingWebhookEvent.find_by!(external_event_id: "evt_invalid_subscription_reference")
    assert_equal "ignored", receipt.status
    assert_includes log_output, "association_code=invalid_account_reference"
    assert_equal original_attributes, subscription_state(account.subscription.reload)
  end

  test "subscription event with another account signed reference is ignored without mutation" do
    account = create_account(name: "Subscription Reference Target")
    other_account = create_account(name: "Subscription Reference Other")
    attempt = create_checkout_attempt(account: account, customer_id: "cus_wrong_subscription_reference")
    original_attributes = subscription_state(account.subscription)

    log_output = capture_rails_logs do
      post_signed_event(
        event_id: "evt_wrong_subscription_reference",
        event_type: "customer.subscription.updated",
        data_object: subscription_data(
          attempt: attempt,
          account_reference: Billing::StripeAccountReference.generate(other_account),
          customer_id: "cus_wrong_subscription_reference",
          subscription_id: "sub_wrong_subscription_reference",
          status: "active"
        )
      )
    end

    assert_response :success
    receipt = BillingWebhookEvent.find_by!(external_event_id: "evt_wrong_subscription_reference")
    assert_equal "ignored", receipt.status
    assert_includes log_output, "association_code=account_mismatch"
    assert_equal original_attributes, subscription_state(account.subscription.reload)
  end

  test "subscription metadata and configured price mismatch is ignored" do
    account = create_account(name: "Mismatched Price Account")
    attempt = create_checkout_attempt(account: account, customer_id: "cus_price_mismatch")
    original_attributes = subscription_state(account.subscription)

    post_signed_event(
      event_id: "evt_price_mismatch",
      event_type: "customer.subscription.created",
      data_object: subscription_data(
        attempt: attempt,
        account_reference: Billing::StripeAccountReference.generate(account),
        customer_id: "cus_price_mismatch",
        subscription_id: "sub_price_mismatch",
        status: "trialing",
        option_key: "self_managed_monthly",
        price_id: "price_webhook_annual"
      )
    )

    assert_response :success
    receipt = BillingWebhookEvent.find_by!(external_event_id: "evt_price_mismatch")
    assert_equal "ignored", receipt.status
    assert_equal original_attributes, subscription_state(account.subscription.reload)
  end

  test "valid unknown event is safely recorded and ignored" do
    post_signed_event(event_id: "evt_unknown", event_type: "customer.created")
    assert_response :success

    receipt = BillingWebhookEvent.find_by!(provider: "stripe", external_event_id: "evt_unknown")
    assert_equal "customer.created", receipt.event_type
    assert_equal "ignored", receipt.status
  end

  test "webhook parameter filter is precise for generic Stripe keys" do
    filtered = parameter_filter.filter(
      "data" => "sensitive data",
      "lines" => "sensitive line items",
      "source" => "sensitive source",
      "metadata" => "ordinary metadata",
      "resource" => "ordinary resource",
      "headlines" => "ordinary headlines",
      "customer" => "cus_sensitive",
      "customer_account" => "acct_sensitive",
      "customer_address" => "private address",
      "hosted_invoice_url" => "https://invoice.stripe.com/i/private",
      "invoice_pdf" => "https://pay.stripe.com/invoice/private.pdf",
      "customer_name" => "Owner Name",
      "customer_note" => "ordinary customer note",
      "customer_phone" => "555-1212",
      "customer_shipping" => "private shipping",
      "customer_success_manager" => "ordinary CSM",
      "customer_tax_ids" => [ "txi_sensitive" ],
      "customer_id" => "cus_parameter_sensitive",
      "charge" => "ch_sensitive",
      "discharge_notes" => "ordinary discharge notes",
      "payment_intent" => "pi_sensitive",
      "price_id" => "price_parameter_sensitive",
      "subscription_id" => "sub_parameter_sensitive",
      "customer_email" => "owner@example.test",
      "prospective_customer" => "ordinary prospect"
    )

    assert_equal "[FILTERED]", filtered["data"]
    assert_equal "[FILTERED]", filtered["lines"]
    assert_equal "[FILTERED]", filtered["source"]
    assert_equal "ordinary metadata", filtered["metadata"]
    assert_equal "ordinary resource", filtered["resource"]
    assert_equal "ordinary headlines", filtered["headlines"]
    assert_equal "[FILTERED]", filtered["customer"]
    assert_equal "[FILTERED]", filtered["customer_account"]
    assert_equal "[FILTERED]", filtered["customer_address"]
    assert_equal "[FILTERED]", filtered["hosted_invoice_url"]
    assert_equal "[FILTERED]", filtered["invoice_pdf"]
    assert_equal "[FILTERED]", filtered["customer_name"]
    assert_equal "ordinary customer note", filtered["customer_note"]
    assert_equal "[FILTERED]", filtered["customer_phone"]
    assert_equal "[FILTERED]", filtered["customer_shipping"]
    assert_equal "ordinary CSM", filtered["customer_success_manager"]
    assert_equal "[FILTERED]", filtered["customer_tax_ids"]
    assert_equal "[FILTERED]", filtered["customer_id"]
    assert_equal "[FILTERED]", filtered["charge"]
    assert_equal "ordinary discharge notes", filtered["discharge_notes"]
    assert_equal "[FILTERED]", filtered["payment_intent"]
    assert_equal "[FILTERED]", filtered["price_id"]
    assert_equal "[FILTERED]", filtered["subscription_id"]
    assert_equal "[FILTERED]", filtered["customer_email"]
    assert_equal "ordinary prospect", filtered["prospective_customer"]
  end

  test "webhook parameter logs filter billing payload and do not duplicate stripe wrapper" do
    data_object = {
      id: "in_sensitive",
      object: "invoice",
      customer: "cus_sensitive",
      customer_email: "owner@example.test",
      hosted_invoice_url: "https://invoice.stripe.com/i/acct_sensitive/test_sensitive",
      invoice_pdf: "https://pay.stripe.com/invoice/acct_sensitive/pdf_sensitive",
      payment_intent: "pi_sensitive",
      lines: {
        data: [
          {
            id: "il_sensitive",
            description: "Private invoice line",
            amount: 49900
          }
        ]
      }
    }
    payload = stripe_event_payload(
      event_id: "evt_payment_succeeded",
      event_type: "invoice.payment_succeeded",
      livemode: true,
      data_object: data_object
    )
    log_output = capture_rails_logs do
      post webhooks_stripe_path, params: payload, headers: stripe_signature_headers(payload)
    end

    assert_response :success

    filtered_parameters = request.filtered_parameters
    assert_equal "[FILTERED]", filtered_parameters["data"]
    assert_not filtered_parameters.key?("stripe")

    assert_includes log_output, "Stripe webhook ignored"
    assert_includes log_output, "reason=deferred"
    assert_includes log_output, "event_id=evt_payment_succeeded"
    assert_includes log_output, "event_type=invoice.payment_succeeded"
    assert_includes log_output, "livemode=true"
    assert_not_includes log_output, "owner@example.test"
    assert_not_includes log_output, "https://invoice.stripe.com"
    assert_not_includes log_output, "https://pay.stripe.com"
    assert_not_includes log_output, "Private invoice line"
    assert_not_includes log_output, "pi_sensitive"
    assert_not_includes log_output, "\"stripe\""

    receipt = BillingWebhookEvent.find_by!(provider: "stripe", external_event_id: "evt_payment_succeeded")
    assert_equal "invoice.payment_succeeded", receipt.event_type
    assert_equal "ignored", receipt.status
  end

  test "duplicate valid delivery returns success without a second receipt" do
    payload = stripe_event_payload(event_id: "evt_duplicate", event_type: "invoice.paid")
    headers = stripe_signature_headers(payload)
    process_count = 0

    assert_difference -> { BillingWebhookEvent.count }, 1 do
      with_process_event_count(process_count) do |counter|
        post webhooks_stripe_path, params: payload, headers: headers
        process_count = counter.call
      end
    end
    assert_response :success
    assert_equal 1, process_count

    assert_no_difference -> { BillingWebhookEvent.count } do
      with_process_event_count(process_count) do |counter|
        post webhooks_stripe_path, params: payload, headers: headers
        process_count = counter.call
      end
    end
    assert_response :success
    assert_equal 1, process_count
  end

  test "failed event receipt is retried and clears failure metadata after success" do
    payload = stripe_event_payload(event_id: "evt_retry_after_failure", event_type: "invoice.payment_failed")
    headers = stripe_signature_headers(payload)

    assert_difference -> { BillingWebhookEvent.count }, 1 do
      with_processor_failure do
        post webhooks_stripe_path, params: payload, headers: headers
      end
    end
    assert_response :internal_server_error

    receipt = BillingWebhookEvent.find_by!(provider: "stripe", external_event_id: "evt_retry_after_failure")
    assert_equal "failed", receipt.status
    assert receipt.failed_at.present?
    assert_equal "RuntimeError", receipt.error_code
    assert_nil receipt.processed_at
    assert_not_includes response.body, "synthetic failure"

    process_count = 0
    assert_no_difference -> { BillingWebhookEvent.count } do
      with_process_event_count(process_count) do |counter|
        post webhooks_stripe_path, params: payload, headers: headers
        process_count = counter.call
      end
    end

    assert_response :success
    assert_equal 1, process_count
    receipt.reload
    assert_equal "ignored", receipt.status
    assert receipt.processed_at.present?
    assert_nil receipt.failed_at
    assert_nil receipt.error_code
  end

  test "failed event receipt remains retryable after repeated failures" do
    payload = stripe_event_payload(event_id: "evt_repeated_failure", event_type: "invoice.payment_failed")
    headers = stripe_signature_headers(payload)
    failure_count = 0

    assert_difference -> { BillingWebhookEvent.count }, 1 do
      with_processor_failure_count(failure_count) do |counter|
        post webhooks_stripe_path, params: payload, headers: headers
        failure_count = counter.call
      end
    end
    assert_response :internal_server_error

    receipt = BillingWebhookEvent.find_by!(provider: "stripe", external_event_id: "evt_repeated_failure")
    first_failed_at = receipt.failed_at
    assert_equal "failed", receipt.status
    assert_equal "RuntimeError", receipt.error_code
    assert_nil receipt.processed_at

    assert_no_difference -> { BillingWebhookEvent.count } do
      with_processor_failure_count(failure_count) do |counter|
        post webhooks_stripe_path, params: payload, headers: headers
        failure_count = counter.call
      end
    end

    assert_response :internal_server_error
    assert_equal 2, failure_count
    receipt.reload
    assert_equal "failed", receipt.status
    assert_operator receipt.failed_at, :>=, first_failed_at
    assert_equal "RuntimeError", receipt.error_code
    assert_nil receipt.processed_at
  end

  test "completed processed receipt is acknowledged without dispatching again" do
    processed_at = 1.hour.ago
    BillingWebhookEvent.create!(
      provider: "stripe",
      external_event_id: "evt_processed_duplicate",
      event_type: "invoice.paid",
      livemode: false,
      status: "processed",
      processed_at: processed_at
    )
    payload = stripe_event_payload(event_id: "evt_processed_duplicate", event_type: "invoice.paid")

    assert_no_difference -> { BillingWebhookEvent.count } do
      with_processor_failure do
        post webhooks_stripe_path, params: payload, headers: stripe_signature_headers(payload)
      end
    end

    assert_response :success
    receipt = BillingWebhookEvent.find_by!(provider: "stripe", external_event_id: "evt_processed_duplicate")
    assert_equal "processed", receipt.status
    assert_equal processed_at.to_i, receipt.processed_at.to_i
    assert_nil receipt.failed_at
    assert_nil receipt.error_code
  end

  test "record not unique recovery acknowledges completed receipts without dispatch" do
    BillingWebhookEvent.create!(
      provider: "stripe",
      external_event_id: "evt_race_completed",
      event_type: "invoice.paid",
      livemode: false,
      status: "ignored",
      processed_at: 1.hour.ago
    )
    payload = stripe_event_payload(event_id: "evt_race_completed", event_type: "invoice.paid")

    assert_no_difference -> { BillingWebhookEvent.count } do
      with_receipt_create_race do
        with_processor_failure do
          post webhooks_stripe_path, params: payload, headers: stripe_signature_headers(payload)
        end
      end
    end

    assert_response :success
  end

  test "record not unique recovery retries failed receipts" do
    BillingWebhookEvent.create!(
      provider: "stripe",
      external_event_id: "evt_race_failed",
      event_type: "invoice.payment_failed",
      livemode: false,
      status: "failed",
      failed_at: 1.hour.ago,
      error_code: "RuntimeError"
    )
    payload = stripe_event_payload(event_id: "evt_race_failed", event_type: "invoice.payment_failed")
    process_count = 0

    assert_no_difference -> { BillingWebhookEvent.count } do
      with_receipt_create_race do
        with_process_event_count(process_count) do |counter|
          post webhooks_stripe_path, params: payload, headers: stripe_signature_headers(payload)
          process_count = counter.call
        end
      end
    end

    assert_response :success
    assert_equal 1, process_count
    receipt = BillingWebhookEvent.find_by!(provider: "stripe", external_event_id: "evt_race_failed")
    assert_equal "ignored", receipt.status
    assert receipt.processed_at.present?
    assert_nil receipt.failed_at
    assert_nil receipt.error_code
  end

  test "missing webhook secret fails safely without exposing secrets" do
    Rails.configuration.x.stripe.webhook_secret = nil

    with_processor_call_failure do
      post webhooks_stripe_path,
        params: stripe_event_payload(event_id: "evt_missing_secret"),
        headers: stripe_signature_headers(stripe_event_payload(event_id: "evt_missing_secret"))
    end

    assert_response :bad_request
    assert_equal "", response.body
    assert_not BillingWebhookEvent.exists?(external_event_id: "evt_missing_secret")
  end

  test "missing and invalid signatures are rejected" do
    payload = stripe_event_payload(event_id: "evt_bad_signature")

    assert_no_difference -> { BillingWebhookEvent.count } do
      with_processor_call_failure do
        post webhooks_stripe_path, params: payload, headers: { "CONTENT_TYPE" => "application/json" }
      end
    end
    assert_response :bad_request

    assert_no_difference -> { BillingWebhookEvent.count } do
      with_processor_call_failure do
        post webhooks_stripe_path,
          params: payload,
          headers: stripe_signature_headers(payload, secret: "wrong_secret")
      end
    end
    assert_response :bad_request
  end

  test "malformed JSON with a valid signature is rejected" do
    payload = "{not-json"

    assert_no_difference -> { BillingWebhookEvent.count } do
      with_processor_call_failure do
        post webhooks_stripe_path, params: payload, headers: stripe_signature_headers(payload)
      end
    end
    assert_response :bad_request
  end

  test "modified payload fails signature verification because raw body is used" do
    signed_payload = stripe_event_payload(event_id: "evt_original")
    modified_payload = stripe_event_payload(event_id: "evt_modified")

    assert_no_difference -> { BillingWebhookEvent.count } do
      with_processor_call_failure do
        post webhooks_stripe_path,
          params: modified_payload,
          headers: stripe_signature_headers(signed_payload)
      end
    end
    assert_response :bad_request
  end

  test "dispatcher failure returns retryable error and records sanitized failure" do
    with_processor_failure do
      post_signed_event(event_id: "evt_dispatch_failure", event_type: "invoice.payment_failed")
    end

    assert_response :internal_server_error
    receipt = BillingWebhookEvent.find_by!(provider: "stripe", external_event_id: "evt_dispatch_failure")
    assert_equal "failed", receipt.status
    assert_equal "RuntimeError", receipt.error_code
    assert receipt.failed_at.present?
    assert_not_includes response.body, "synthetic failure"
  end

  test "webhook events do not change local subscription lifecycle state in this phase" do
    account = create_account(name: "Stripe Foundation Owner")
    original_attributes = account.subscription.attributes.slice("plan", "status", "provider", "external_customer_id", "external_subscription_id")

    post_signed_event(event_id: "evt_no_subscription_sync", event_type: "customer.subscription.deleted")
    assert_response :success

    assert_equal original_attributes, account.subscription.reload.attributes.slice("plan", "status", "provider", "external_customer_id", "external_subscription_id")
  end

  private

  def option_catalog(enabled:)
    definitions = Billing::SubscriptionPlanCatalog::DEFAULT_DEFINITIONS.map(&:deep_dup)
    definitions.find { |definition| definition.fetch(:key) == "self_managed_monthly" }[:enabled] = enabled

    Billing::SubscriptionPlanCatalog.new(
      price_ids: {
        "self_managed_monthly" => "price_webhook_monthly",
        "self_managed_annual" => "price_webhook_annual"
      },
      definitions: definitions
    )
  end

  def with_plan_catalog(catalog)
    original_method = Billing::SubscriptionPlanCatalog.method(:new)
    Billing::SubscriptionPlanCatalog.define_singleton_method(:new, ->(*) { catalog })

    yield
  ensure
    Billing::SubscriptionPlanCatalog.define_singleton_method(:new, original_method)
  end

  def post_signed_event(event_id:, event_type: "customer.subscription.updated", livemode: false,
    api_version: "2026-07-01", data_object: nil, event_created: Time.current.to_i)
    payload = stripe_event_payload(
      event_id: event_id,
      event_type: event_type,
      livemode: livemode,
      api_version: api_version,
      data_object: data_object,
      event_created: event_created
    )
    post webhooks_stripe_path, params: payload, headers: stripe_signature_headers(payload)
  end

  def stripe_event_payload(event_id:, event_type: "customer.subscription.updated", livemode: false,
    api_version: "2026-07-01", data_object: nil, event_created: Time.current.to_i)
    JSON.generate(
      id: event_id,
      object: "event",
      type: event_type,
      created: event_created,
      livemode: livemode,
      api_version: api_version,
      data: {
        object: data_object || {
          id: "sub_test",
          object: "subscription"
        }
      }
    )
  end

  def stripe_signature_headers(payload, secret: WEBHOOK_SECRET)
    timestamp = Time.current
    signature = Stripe::Webhook::Signature.compute_signature(timestamp, payload, secret)
    {
      "CONTENT_TYPE" => "application/json",
      "Stripe-Signature" => Stripe::Webhook::Signature.generate_header(timestamp, signature)
    }
  end

  def checkout_session_data(attempt:, account_reference:, customer_id:, subscription_id:,
    option_key: "self_managed_monthly")
    {
      id: attempt.stripe_checkout_session_id,
      object: "checkout.session",
      mode: "subscription",
      customer: customer_id,
      subscription: subscription_id,
      client_reference_id: account_reference,
      metadata: {
        Billing::StripeCheckoutSessionCreator::ACCOUNT_REFERENCE_KEY => account_reference,
        Billing::StripeCheckoutSessionCreator::ATTEMPT_REFERENCE_KEY =>
          Billing::StripeCheckoutAttemptReference.generate(attempt),
        Billing::StripeCheckoutSessionCreator::OPTION_KEY => option_key
      }
    }
  end

  def subscription_data(attempt:, account_reference:, customer_id:, subscription_id:, status:,
    option_key: "self_managed_monthly", price_id: "price_webhook_monthly",
    trial_end: 7.days.from_now, period_end: 1.month.from_now,
    cancel_at_period_end: false, canceled_at: nil)
    {
      id: subscription_id,
      object: "subscription",
      customer: customer_id,
      status: status,
      trial_end: trial_end&.to_i,
      cancel_at_period_end: cancel_at_period_end,
      canceled_at: canceled_at&.to_i,
      metadata: {
        Billing::StripeCheckoutSessionCreator::ACCOUNT_REFERENCE_KEY => account_reference,
        Billing::StripeCheckoutSessionCreator::ATTEMPT_REFERENCE_KEY =>
          Billing::StripeCheckoutAttemptReference.generate(attempt),
        Billing::StripeCheckoutSessionCreator::OPTION_KEY => option_key
      },
      items: {
        data: [
          {
            price: { id: price_id },
            current_period_end: period_end&.to_i
          }
        ]
      }
    }
  end

  def create_checkout_attempt(account:, customer_id:, session_id: SecureRandom.uuid,
    option_key: "self_managed_monthly", status: "open")
    BillingCheckoutAttempt.create!(
      account: account,
      option_key: option_key,
      stripe_customer_id: customer_id,
      stripe_checkout_session_id: session_id,
      idempotency_key: SecureRandom.uuid,
      status: status
    )
  end

  def subscription_state(subscription)
    subscription.attributes.slice(
      "plan",
      "status",
      "provider",
      "external_customer_id",
      "external_subscription_id",
      "trial_ends_at",
      "current_period_ends_at",
      "cancel_at_period_end",
      "canceled_at",
      "last_synced_at",
      "stripe_last_event_created_at",
      "stripe_last_event_id"
    )
  end

  def parameter_filter
    ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
  end

  def capture_rails_logs
    previous_logger = Rails.logger
    output = StringIO.new
    Rails.logger = ActiveSupport::TaggedLogging.new(ActiveSupport::Logger.new(output))

    yield

    output.string
  ensure
    Rails.logger = previous_logger
  end

  def csrf_skipped_for_action?(controller, action)
    csrf_skip_actions(controller).include?(action.to_s)
  end

  def csrf_skip_actions(controller)
    callback = controller._process_action_callbacks.find do |candidate|
      candidate.kind == :before && candidate.filter == :verify_authenticity_token
    end
    return [] unless callback

    callback.instance_variable_get(:@unless).filter_map do |condition|
      condition.instance_variable_get(:@actions)&.to_a
    end.flatten.sort
  end

  def with_processor_failure
    original_method = Billing::StripeWebhookProcessor.instance_method(:process_event!)
    Billing::StripeWebhookProcessor.define_method(:process_event!) do |_billing_webhook_event|
      raise "synthetic failure"
    end
    Billing::StripeWebhookProcessor.send(:private, :process_event!)

    yield
  ensure
    Billing::StripeWebhookProcessor.define_method(:process_event!, original_method)
    Billing::StripeWebhookProcessor.send(:private, :process_event!)
  end

  def with_processor_failure_count(initial_count)
    count = initial_count
    original_method = Billing::StripeWebhookProcessor.instance_method(:process_event!)
    Billing::StripeWebhookProcessor.define_method(:process_event!) do |_billing_webhook_event|
      count += 1
      raise "synthetic failure"
    end
    Billing::StripeWebhookProcessor.send(:private, :process_event!)

    yield -> { count }
  ensure
    Billing::StripeWebhookProcessor.define_method(:process_event!, original_method)
    Billing::StripeWebhookProcessor.send(:private, :process_event!)
  end

  def with_processor_call_failure
    original_method = Billing::StripeWebhookProcessor.method(:call)
    Billing::StripeWebhookProcessor.define_singleton_method(:call) do |_event|
      raise "processor should not run"
    end

    yield
  ensure
    Billing::StripeWebhookProcessor.define_singleton_method(:call, original_method)
  end

  def with_processor_call_spy(dispatched_event_ids)
    original_method = Billing::StripeWebhookProcessor.method(:call)
    Billing::StripeWebhookProcessor.define_singleton_method(:call) do |event|
      dispatched_event_ids << event.id
      original_method.call(event)
    end

    yield
  ensure
    Billing::StripeWebhookProcessor.define_singleton_method(:call, original_method)
  end

  def with_process_event_count(initial_count)
    count = initial_count
    original_method = Billing::StripeWebhookProcessor.instance_method(:process_event!)
    Billing::StripeWebhookProcessor.define_method(:process_event!) do |billing_webhook_event|
      count += 1
      original_method.bind_call(self, billing_webhook_event)
    end
    Billing::StripeWebhookProcessor.send(:private, :process_event!)

    yield -> { count }
  ensure
    Billing::StripeWebhookProcessor.define_method(:process_event!, original_method)
    Billing::StripeWebhookProcessor.send(:private, :process_event!)
  end

  def with_forgery_protection
    previous_application_value = ApplicationController.allow_forgery_protection
    previous_base_value = ActionController::Base.allow_forgery_protection
    ApplicationController.allow_forgery_protection = true
    ActionController::Base.allow_forgery_protection = true

    yield
  ensure
    ApplicationController.allow_forgery_protection = previous_application_value
    ActionController::Base.allow_forgery_protection = previous_base_value
  end

  def with_receipt_create_race
    original_find_by = BillingWebhookEvent.method(:find_by)
    original_create = BillingWebhookEvent.method(:create!)
    find_by_calls = 0
    create_calls = 0

    BillingWebhookEvent.define_singleton_method(:find_by) do |*args, **kwargs|
      find_by_calls += 1
      next nil if find_by_calls == 1

      original_find_by.call(*args, **kwargs)
    end
    BillingWebhookEvent.define_singleton_method(:create!) do |*args, **kwargs|
      create_calls += 1
      raise ActiveRecord::RecordNotUnique if create_calls == 1

      original_create.call(*args, **kwargs)
    end

    yield
  ensure
    BillingWebhookEvent.define_singleton_method(:find_by, original_find_by)
    BillingWebhookEvent.define_singleton_method(:create!, original_create)
  end

  def with_stripe_webhook_verification_failure
    original_method = Stripe::Webhook.method(:construct_event)
    Stripe::Webhook.define_singleton_method(:construct_event) do |*|
      raise "Stripe verification should not run"
    end

    yield
  ensure
    Stripe::Webhook.define_singleton_method(:construct_event, original_method)
  end
end
