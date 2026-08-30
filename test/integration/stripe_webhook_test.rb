require "test_helper"

class StripeWebhookTest < ActionDispatch::IntegrationTest
  WEBHOOK_SECRET = "whsec_test_secret"
  EVENT_DATA_AS_CANONICAL = Object.new.freeze

  setup do
    @previous_secret_key = Rails.configuration.x.stripe.secret_key
    @previous_webhook_secret = Rails.configuration.x.stripe.webhook_secret
    @previous_livemode = Rails.configuration.x.stripe.livemode
    @previous_monthly_price_id = Rails.configuration.x.stripe.self_managed_monthly_price_id
    @previous_annual_price_id = Rails.configuration.x.stripe.self_managed_annual_price_id
    Rails.configuration.x.stripe.secret_key = "sk_test_webhook_canonical"
    Rails.configuration.x.stripe.webhook_secret = WEBHOOK_SECRET
    Rails.configuration.x.stripe.livemode = false
    Rails.configuration.x.stripe.self_managed_monthly_price_id = "price_webhook_monthly"
    Rails.configuration.x.stripe.self_managed_annual_price_id = "price_webhook_annual"
  end

  teardown do
    Rails.configuration.x.stripe.secret_key = @previous_secret_key
    Rails.configuration.x.stripe.webhook_secret = @previous_webhook_secret
    Rails.configuration.x.stripe.livemode = @previous_livemode
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

    with_stripe_subscription_retrieve(->(*) { flunk("normal requests must not retrieve Stripe subscriptions") }) do
      with_stripe_webhook_verification_failure do
        get root_path
      end
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

  test "valid signed deferred invoice event is accepted and recorded as ignored" do
    dispatched_event_ids = []

    assert_difference -> { BillingWebhookEvent.count }, 1 do
      with_processor_call_spy(dispatched_event_ids) do
        post_signed_event(
          event_id: "evt_payment_succeeded_deferred",
          event_type: "invoice.payment_succeeded",
          api_version: "2026-07-01"
        )
      end
    end

    assert_response :success
    assert_equal [ "evt_payment_succeeded_deferred" ], dispatched_event_ids
    receipt = BillingWebhookEvent.find_by!(provider: "stripe", external_event_id: "evt_payment_succeeded_deferred")
    assert_equal "invoice.payment_succeeded", receipt.event_type
    assert_not receipt.livemode?
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

  test "signed replacement events hand off the existing local Subscription without granting a trial" do
    now = Time.zone.local(2026, 8, 28, 12)
    ended_at = now - 2.days
    period_end = now + 1.month
    account = create_account(name: "Webhook Reactivation Owner")
    account_reference = Billing::StripeAccountReference.generate(account)
    old_attempt = create_checkout_attempt(
      account:,
      customer_id: "cus_reactivation_handoff",
      session_id: "cs_reactivation_old",
      status: "completed"
    )
    replacement_attempt = create_checkout_attempt(
      account:,
      customer_id: "cus_reactivation_handoff",
      session_id: "cs_reactivation_new",
      status: "open",
      replaces_external_subscription_id: "sub_reactivation_old"
    )
    configure_terminal_subscription(
      account,
      customer_id: "cus_reactivation_handoff",
      subscription_id: "sub_reactivation_old",
      ended_at:
    )
    subscription_id = account.subscription.id
    record_counts = [ Account.count, Subscription.count ]

    travel_to now do
      post_signed_event(
        event_id: "evt_reactivation_checkout",
        event_type: "checkout.session.completed",
        data_object: checkout_session_data(
          attempt: replacement_attempt,
          account_reference:,
          customer_id: "cus_reactivation_handoff",
          subscription_id: "sub_reactivation_new"
        )
      )
      assert_response :success

      subscription = account.subscription.reload
      assert_equal subscription_id, subscription.id
      assert_equal "sub_reactivation_new", subscription.external_subscription_id
      assert_equal "canceled", subscription.status
      assert_not Billing::SelfManagedEntitlement.new(account:, now:).qualifying?
      assert_equal "processed", BillingWebhookEvent.find_by!(external_event_id: "evt_reactivation_checkout").status

      post_signed_event(
        event_id: "evt_reactivation_subscription",
        event_type: "customer.subscription.created",
        data_object: subscription_data(
          attempt: replacement_attempt,
          account_reference:,
          customer_id: "cus_reactivation_handoff",
          subscription_id: "sub_reactivation_new",
          status: "active",
          trial_end: nil,
          period_end:
        )
      )
      assert_response :success
    end

    subscription = account.subscription.reload
    assert_equal subscription_id, subscription.id
    assert_equal "cus_reactivation_handoff", subscription.external_customer_id
    assert_equal "sub_reactivation_new", subscription.external_subscription_id
    assert_equal "active", subscription.status
    assert_nil subscription.trial_ends_at
    assert_equal ended_at.to_i, subscription.entitlement_ended_at.to_i
    assert Billing::SelfManagedEntitlement.new(account:, now:).qualifying?
    assert_equal "completed", replacement_attempt.reload.status
    assert_equal "completed", old_attempt.reload.status
    assert_equal record_counts, [ Account.count, Subscription.count ]
    assert_equal "processed", BillingWebhookEvent.find_by!(external_event_id: "evt_reactivation_subscription").status
  end

  test "canonical replacement event can complete the handoff before Checkout completion" do
    now = Time.zone.local(2026, 8, 28, 12)
    account = create_account(name: "Webhook Reactivation Ordering")
    account_reference = Billing::StripeAccountReference.generate(account)
    replacement_attempt = create_checkout_attempt(
      account:,
      customer_id: "cus_reactivation_order",
      session_id: "cs_reactivation_order",
      status: "open",
      replaces_external_subscription_id: "sub_reactivation_order_old"
    )
    configure_terminal_subscription(
      account,
      customer_id: "cus_reactivation_order",
      subscription_id: "sub_reactivation_order_old",
      ended_at: now - 1.day
    )

    travel_to now do
      post_signed_event(
        event_id: "evt_reactivation_subscription_first",
        event_type: "customer.subscription.created",
        data_object: subscription_data(
          attempt: replacement_attempt,
          account_reference:,
          customer_id: "cus_reactivation_order",
          subscription_id: "sub_reactivation_order_new",
          status: "active",
          trial_end: nil,
          period_end: now + 1.month
        )
      )
      assert_response :success
      assert_equal "sub_reactivation_order_new", account.subscription.reload.external_subscription_id
      assert_equal "completed", replacement_attempt.reload.status

      post_signed_event(
        event_id: "evt_reactivation_checkout_late",
        event_type: "checkout.session.completed",
        data_object: checkout_session_data(
          attempt: replacement_attempt,
          account_reference:,
          customer_id: "cus_reactivation_order",
          subscription_id: "sub_reactivation_order_new"
        )
      )
      assert_response :success
    end

    assert_equal "processed", BillingWebhookEvent.find_by!(external_event_id: "evt_reactivation_subscription_first").status
    assert_equal "processed", BillingWebhookEvent.find_by!(external_event_id: "evt_reactivation_checkout_late").status
    assert_equal "active", account.subscription.reload.status
  end

  test "delayed old subscription events cannot reclaim a completed replacement association" do
    now = Time.zone.local(2026, 8, 28, 12)
    account = create_account(name: "Webhook Old Subscription Delay")
    account_reference = Billing::StripeAccountReference.generate(account)
    old_attempt = create_checkout_attempt(
      account:,
      customer_id: "cus_old_event_delay",
      session_id: "cs_old_event_delay",
      status: "completed"
    )
    replacement_attempt = create_checkout_attempt(
      account:,
      customer_id: "cus_old_event_delay",
      session_id: "cs_new_event_delay",
      status: "completed",
      replaces_external_subscription_id: "sub_old_event_delay"
    )
    account.subscription.update!(
      provider: "stripe",
      plan: "self_managed",
      status: "active",
      external_customer_id: "cus_old_event_delay",
      external_subscription_id: "sub_new_event_delay",
      current_period_ends_at: now + 1.month,
      entitlement_ended_at: now - 1.day,
      last_synced_at: now
    )
    original_state = subscription_state(account.subscription)

    travel_to now do
      post_signed_event(
        event_id: "evt_delayed_old_subscription",
        event_type: "customer.subscription.updated",
        data_object: subscription_data(
          attempt: old_attempt,
          account_reference:,
          customer_id: "cus_old_event_delay",
          subscription_id: "sub_old_event_delay",
          status: "canceled",
          trial_end: nil,
          period_end: now - 1.day
        )
      )
    end

    assert_response :success
    assert_equal "ignored", BillingWebhookEvent.find_by!(external_event_id: "evt_delayed_old_subscription").status
    assert_equal original_state, subscription_state(account.subscription)
    assert_equal "completed", replacement_attempt.reload.status
  end

  test "a replacement Subscription with trial state fails closed without entitlement" do
    now = Time.zone.local(2026, 8, 28, 12)
    account = create_account(name: "Webhook Reactivation Trial Refusal")
    account_reference = Billing::StripeAccountReference.generate(account)
    attempt = create_checkout_attempt(
      account:,
      customer_id: "cus_reactivation_trial",
      session_id: "cs_reactivation_trial",
      status: "open",
      replaces_external_subscription_id: "sub_reactivation_trial_old"
    )
    configure_terminal_subscription(
      account,
      customer_id: "cus_reactivation_trial",
      subscription_id: "sub_reactivation_trial_old",
      ended_at: now - 1.day
    )
    original_state = subscription_state(account.subscription)

    travel_to now do
      post_signed_event(
        event_id: "evt_reactivation_trial_refused",
        event_type: "customer.subscription.created",
        data_object: subscription_data(
          attempt:,
          account_reference:,
          customer_id: "cus_reactivation_trial",
          subscription_id: "sub_reactivation_trial_new",
          status: "trialing",
          trial_end: now + 7.days,
          period_end: now + 1.month
        )
      )
    end

    assert_response :success
    assert_equal "ignored", BillingWebhookEvent.find_by!(external_event_id: "evt_reactivation_trial_refused").status
    assert_equal original_state, subscription_state(account.subscription)
    assert_not Billing::SelfManagedEntitlement.new(account:, now:).qualifying?
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

  test "subscription event missing option metadata is ignored before canonical retrieval" do
    account = create_account(name: "Missing Event Option Metadata")
    attempt = create_checkout_attempt(account: account, customer_id: "cus_missing_event_option")
    original_attributes = subscription_state(account.subscription)
    event_data = subscription_data(
      attempt: attempt,
      account_reference: Billing::StripeAccountReference.generate(account),
      customer_id: "cus_missing_event_option",
      subscription_id: "sub_missing_event_option",
      status: "trialing"
    )
    event_data[:metadata].delete(Billing::StripeCheckoutSessionCreator::OPTION_KEY)
    retrieve_count = 0

    log_output = capture_rails_logs do
      with_stripe_subscription_retrieve(->(*) { retrieve_count += 1 }) do
        post_signed_event(
          event_id: "evt_missing_event_option",
          event_type: "customer.subscription.created",
          data_object: event_data,
          canonical_subscription: nil
        )
      end
    end

    assert_response :success
    receipt = BillingWebhookEvent.find_by!(external_event_id: "evt_missing_event_option")
    assert_equal "ignored", receipt.status
    assert_includes log_output, "association_code=missing_option_key"
    assert_equal 0, retrieve_count
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

  test "duplicate processed subscription event is acknowledged without retrieving twice" do
    account = create_account(name: "Duplicate Subscription Event Owner")
    attempt = create_checkout_attempt(account: account, customer_id: "cus_subscription_duplicate")
    data_object = subscription_data(
      attempt: attempt,
      account_reference: Billing::StripeAccountReference.generate(account),
      customer_id: "cus_subscription_duplicate",
      subscription_id: "sub_subscription_duplicate",
      status: "trialing"
    )
    payload = stripe_event_payload(
      event_id: "evt_subscription_duplicate",
      event_type: "customer.subscription.created",
      data_object: data_object
    )
    headers = stripe_signature_headers(payload)

    retrieve_count = 0
    with_stripe_subscription_retrieve(->(*) {
      retrieve_count += 1
      stripe_subscription(data_object)
    }) do
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

    assert_equal 1, retrieve_count
  end

  test "same-second lifecycle events converge on canonical state despite conflicting event id order" do
    account = create_account(name: "Same Second Canonical State")
    attempt = create_checkout_attempt(account: account, customer_id: "cus_same_second")
    account_reference = Billing::StripeAccountReference.generate(account)
    canonical_data = subscription_data(
      attempt: attempt,
      account_reference: account_reference,
      customer_id: "cus_same_second",
      subscription_id: "sub_same_second",
      status: "active",
      trial_end: nil,
      period_end: 3.months.from_now
    )
    snapshots = [
      [ "evt_z_older", "trialing", true ],
      [ "evt_a_newer", "past_due", false ]
    ]

    snapshots.each do |event_id, event_status, cancel_at_period_end|
      post_signed_event(
        event_id: event_id,
        event_type: "customer.subscription.updated",
        event_created: 300,
        data_object: subscription_data(
          attempt: attempt.reload,
          account_reference: account_reference,
          customer_id: "cus_same_second",
          subscription_id: "sub_same_second",
          status: event_status,
          cancel_at_period_end: cancel_at_period_end
        ),
        canonical_subscription: canonical_data
      )

      assert_response :success
      assert_equal "processed", BillingWebhookEvent.find_by!(external_event_id: event_id).status
      assert_equal "active", account.subscription.reload.status
      assert_not account.subscription.cancel_at_period_end?
    end
  end

  test "older and newer event delivery orders converge on the same canonical state" do
    [ %i[older newer], %i[newer older] ].each do |delivery_order|
      account = create_account(name: "Canonical Order #{delivery_order.join('-')}")
      customer_id = "cus_order_#{delivery_order.join('_')}"
      subscription_id = "sub_order_#{delivery_order.join('_')}"
      attempt = create_checkout_attempt(account: account, customer_id: customer_id)
      account_reference = Billing::StripeAccountReference.generate(account)
      canonical_data = subscription_data(
        attempt: attempt,
        account_reference: account_reference,
        customer_id: customer_id,
        subscription_id: subscription_id,
        status: "active",
        trial_end: nil,
        period_end: 3.months.from_now
      )
      events = {
        older: [ "evt_z_#{customer_id}_older", 100, "trialing" ],
        newer: [ "evt_a_#{customer_id}_newer", 200, "active" ]
      }

      delivery_order.each do |position|
        event_id, event_created, event_status = events.fetch(position)
        post_signed_event(
          event_id: event_id,
          event_type: "customer.subscription.updated",
          event_created: event_created,
          data_object: subscription_data(
            attempt: attempt.reload,
            account_reference: account_reference,
            customer_id: customer_id,
            subscription_id: subscription_id,
            status: event_status
          ),
          canonical_subscription: canonical_data
        )
        assert_response :success
      end

      subscription = account.subscription.reload
      assert_equal "active", subscription.status
      assert_nil subscription.trial_ends_at
      processed_receipts = delivery_order.count do |position|
        BillingWebhookEvent.find_by!(external_event_id: events.fetch(position).first).processed?
      end
      assert_equal 2, processed_receipts
    end
  end

  test "canonical Subscription retrieval occurs before the webhook receipt transaction" do
    account = create_account(name: "Canonical Retrieval Transaction Boundary")
    attempt = create_checkout_attempt(account: account, customer_id: "cus_retrieval_transaction")
    event_data = subscription_data(
      attempt: attempt,
      account_reference: Billing::StripeAccountReference.generate(account),
      customer_id: "cus_retrieval_transaction",
      subscription_id: "sub_retrieval_transaction",
      status: "trialing"
    )
    baseline_transactions = ActiveRecord::Base.connection.open_transactions
    retrieval_transactions = []

    with_stripe_subscription_retrieve(->(*) {
      retrieval_transactions << ActiveRecord::Base.connection.open_transactions
      stripe_subscription(event_data)
    }) do
      post_signed_event(
        event_id: "evt_retrieval_transaction",
        event_type: "customer.subscription.created",
        data_object: event_data,
        canonical_subscription: nil
      )
    end

    assert_response :success
    assert_equal [ baseline_transactions ], retrieval_transactions
    assert_equal "processed", BillingWebhookEvent.find_by!(external_event_id: "evt_retrieval_transaction").status
  end

  test "Stripe subscription retrieval failure leaves the webhook retryable" do
    account = create_account(name: "Canonical Retrieval Failure")
    attempt = create_checkout_attempt(account: account, customer_id: "cus_retrieval_failure")
    original_attributes = subscription_state(account.subscription)
    event_data = subscription_data(
      attempt: attempt,
      account_reference: Billing::StripeAccountReference.generate(account),
      customer_id: "cus_retrieval_failure",
      subscription_id: "sub_retrieval_failure",
      status: "trialing"
    )

    with_stripe_subscription_retrieve(->(*) {
      raise Stripe::APIConnectionError, "private transport failure"
    }) do
      post_signed_event(
        event_id: "evt_retrieval_failure",
        event_type: "customer.subscription.created",
        data_object: event_data,
        canonical_subscription: nil
      )
    end

    assert_response :internal_server_error
    receipt = BillingWebhookEvent.find_by!(external_event_id: "evt_retrieval_failure")
    assert_equal "failed", receipt.status
    assert_equal "APIConnectionError", receipt.error_code
    assert receipt.failed_at.present?
    assert_nil receipt.processed_at
    assert_equal original_attributes, subscription_state(account.subscription.reload)
    assert_equal "open", attempt.reload.status
    assert_not_includes response.body, "private transport failure"

    post_signed_event(
      event_id: "evt_retrieval_failure",
      event_type: "customer.subscription.created",
      data_object: event_data
    )

    assert_response :success
    assert_equal "processed", receipt.reload.status
    assert_equal "trialing", account.subscription.reload.status
    assert_equal "completed", attempt.reload.status
  end

  test "account reconciliation lock timeout remains a retryable webhook failure" do
    account = create_account(name: "Reconciliation Lock Timeout")
    attempt = create_checkout_attempt(account: account, customer_id: "cus_lock_timeout")
    event_data = subscription_data(
      attempt: attempt,
      account_reference: Billing::StripeAccountReference.generate(account),
      customer_id: "cus_lock_timeout",
      subscription_id: "sub_lock_timeout",
      status: "trialing"
    )
    original_call = Billing::StripeAccountReconciliationLock.method(:call)
    calls = 0

    Billing::StripeAccountReconciliationLock.define_singleton_method(:call) do |account_id:, **options, &block|
      calls += 1
      raise Billing::StripeAccountReconciliationLock::LockTimeoutError,
        "Stripe account reconciliation is already in progress" if calls == 1

      original_call.call(account_id:, **options, &block)
    end

    post_signed_event(
      event_id: "evt_lock_timeout",
      event_type: "customer.subscription.created",
      data_object: event_data
    )

    assert_response :internal_server_error
    receipt = BillingWebhookEvent.find_by!(external_event_id: "evt_lock_timeout")
    assert_equal "failed", receipt.status
    assert_equal "LockTimeoutError", receipt.error_code
    assert_equal "open", attempt.reload.status

    post_signed_event(
      event_id: "evt_lock_timeout",
      event_type: "customer.subscription.created",
      data_object: event_data
    )

    assert_response :success
    assert_equal "processed", receipt.reload.status
    assert_equal "trialing", account.subscription.reload.status
    assert_equal "completed", attempt.reload.status
  ensure
    Billing::StripeAccountReconciliationLock.define_singleton_method(:call, original_call) if original_call
  end

  test "canonical Subscription Customer mismatch is ignored without mutation" do
    account = create_account(name: "Canonical Customer Mismatch")
    attempt = create_checkout_attempt(account: account, customer_id: "cus_event_customer")
    original_attributes = subscription_state(account.subscription)
    event_data = subscription_data(
      attempt: attempt,
      account_reference: Billing::StripeAccountReference.generate(account),
      customer_id: "cus_event_customer",
      subscription_id: "sub_customer_mismatch",
      status: "trialing"
    )
    canonical_data = event_data.deep_dup.merge(customer: "cus_other_customer")

    post_signed_event(
      event_id: "evt_canonical_customer_mismatch",
      event_type: "customer.subscription.created",
      data_object: event_data,
      canonical_subscription: canonical_data
    )

    assert_response :success
    receipt = BillingWebhookEvent.find_by!(external_event_id: "evt_canonical_customer_mismatch")
    assert_equal "ignored", receipt.status
    assert_equal original_attributes, subscription_state(account.subscription.reload)
    assert_equal "open", attempt.reload.status
  end

  test "canonical Subscription ID mismatch is ignored without mutation" do
    account = create_account(name: "Canonical Subscription Mismatch")
    attempt = create_checkout_attempt(account: account, customer_id: "cus_subscription_mismatch")
    original_attributes = subscription_state(account.subscription)
    event_data = subscription_data(
      attempt: attempt,
      account_reference: Billing::StripeAccountReference.generate(account),
      customer_id: "cus_subscription_mismatch",
      subscription_id: "sub_expected",
      status: "trialing"
    )
    canonical_data = event_data.deep_dup.merge(id: "sub_unexpected")

    post_signed_event(
      event_id: "evt_canonical_subscription_mismatch",
      event_type: "customer.subscription.created",
      data_object: event_data,
      canonical_subscription: canonical_data
    )

    assert_response :success
    receipt = BillingWebhookEvent.find_by!(external_event_id: "evt_canonical_subscription_mismatch")
    assert_equal "ignored", receipt.status
    assert_equal original_attributes, subscription_state(account.subscription.reload)
    assert_equal "open", attempt.reload.status
  end

  test "canonical Subscription Price mismatch is ignored without mutation" do
    account = create_account(name: "Canonical Price Mismatch")
    attempt = create_checkout_attempt(account: account, customer_id: "cus_canonical_price_mismatch")
    original_attributes = subscription_state(account.subscription)
    event_data = subscription_data(
      attempt: attempt,
      account_reference: Billing::StripeAccountReference.generate(account),
      customer_id: "cus_canonical_price_mismatch",
      subscription_id: "sub_canonical_price_mismatch",
      status: "trialing"
    )
    canonical_data = event_data.deep_dup
    canonical_data[:items][:data].first[:price][:id] = "price_webhook_annual"

    post_signed_event(
      event_id: "evt_canonical_price_mismatch",
      event_type: "customer.subscription.created",
      data_object: event_data,
      canonical_subscription: canonical_data
    )

    assert_response :success
    receipt = BillingWebhookEvent.find_by!(external_event_id: "evt_canonical_price_mismatch")
    assert_equal "ignored", receipt.status
    assert_equal original_attributes, subscription_state(account.subscription.reload)
    assert_equal "open", attempt.reload.status
  end

  test "canonical Subscription missing option metadata is ignored without mutation" do
    account = create_account(name: "Canonical Missing Option Metadata")
    attempt = create_checkout_attempt(account: account, customer_id: "cus_canonical_missing_option")
    original_attributes = subscription_state(account.subscription)
    event_data = subscription_data(
      attempt: attempt,
      account_reference: Billing::StripeAccountReference.generate(account),
      customer_id: "cus_canonical_missing_option",
      subscription_id: "sub_canonical_missing_option",
      status: "trialing"
    )
    canonical_data = event_data.deep_dup
    canonical_data[:metadata].delete(Billing::StripeCheckoutSessionCreator::OPTION_KEY)

    log_output = capture_rails_logs do
      post_signed_event(
        event_id: "evt_canonical_missing_option",
        event_type: "customer.subscription.created",
        data_object: event_data,
        canonical_subscription: canonical_data
      )
    end

    assert_response :success
    receipt = BillingWebhookEvent.find_by!(external_event_id: "evt_canonical_missing_option")
    assert_equal "ignored", receipt.status
    assert_includes log_output, "association_code=missing_option_key"
    assert_equal original_attributes, subscription_state(account.subscription.reload)
    assert_equal "open", attempt.reload.status
  end

  test "canonical Subscription option metadata mismatch is ignored without mutation" do
    account = create_account(name: "Canonical Option Metadata Mismatch")
    attempt = create_checkout_attempt(account: account, customer_id: "cus_canonical_option_mismatch")
    original_attributes = subscription_state(account.subscription)
    event_data = subscription_data(
      attempt: attempt,
      account_reference: Billing::StripeAccountReference.generate(account),
      customer_id: "cus_canonical_option_mismatch",
      subscription_id: "sub_canonical_option_mismatch",
      status: "trialing"
    )
    canonical_data = event_data.deep_dup
    canonical_data[:metadata][Billing::StripeCheckoutSessionCreator::OPTION_KEY] = "self_managed_annual"

    log_output = capture_rails_logs do
      post_signed_event(
        event_id: "evt_canonical_option_mismatch",
        event_type: "customer.subscription.created",
        data_object: event_data,
        canonical_subscription: canonical_data
      )
    end

    assert_response :success
    receipt = BillingWebhookEvent.find_by!(external_event_id: "evt_canonical_option_mismatch")
    assert_equal "ignored", receipt.status
    assert_includes log_output, "association_code=option_price_mismatch"
    assert_equal original_attributes, subscription_state(account.subscription.reload)
    assert_equal "open", attempt.reload.status
  end

  test "canonical signed Checkout attempt mismatch is ignored without mutation" do
    account = create_account(name: "Canonical Attempt Mismatch")
    attempt = create_checkout_attempt(account: account, customer_id: "cus_canonical_attempt")
    other_attempt = create_checkout_attempt(
      account: account,
      customer_id: "cus_other_attempt",
      status: "canceled"
    )
    original_attributes = subscription_state(account.subscription)
    event_data = subscription_data(
      attempt: attempt,
      account_reference: Billing::StripeAccountReference.generate(account),
      customer_id: "cus_canonical_attempt",
      subscription_id: "sub_canonical_attempt",
      status: "trialing"
    )
    canonical_data = event_data.deep_dup
    canonical_data[:metadata][Billing::StripeCheckoutSessionCreator::ATTEMPT_REFERENCE_KEY] =
      Billing::StripeCheckoutAttemptReference.generate(other_attempt)

    post_signed_event(
      event_id: "evt_canonical_attempt_mismatch",
      event_type: "customer.subscription.created",
      data_object: event_data,
      canonical_subscription: canonical_data
    )

    assert_response :success
    receipt = BillingWebhookEvent.find_by!(external_event_id: "evt_canonical_attempt_mismatch")
    assert_equal "ignored", receipt.status
    assert_equal original_attributes, subscription_state(account.subscription.reload)
    assert_equal "open", attempt.reload.status
  end

  test "canonical signed Account reference mismatch is ignored without mutation" do
    account = create_account(name: "Canonical Account Reference Target")
    other_account = create_account(name: "Canonical Account Reference Other")
    attempt = create_checkout_attempt(account: account, customer_id: "cus_canonical_account_reference")
    original_attributes = subscription_state(account.subscription)
    event_data = subscription_data(
      attempt: attempt,
      account_reference: Billing::StripeAccountReference.generate(account),
      customer_id: "cus_canonical_account_reference",
      subscription_id: "sub_canonical_account_reference",
      status: "trialing"
    )
    canonical_data = event_data.deep_dup
    canonical_data[:metadata][Billing::StripeCheckoutSessionCreator::ACCOUNT_REFERENCE_KEY] =
      Billing::StripeAccountReference.generate(other_account)

    post_signed_event(
      event_id: "evt_canonical_account_reference_mismatch",
      event_type: "customer.subscription.created",
      data_object: event_data,
      canonical_subscription: canonical_data
    )

    assert_response :success
    receipt = BillingWebhookEvent.find_by!(external_event_id: "evt_canonical_account_reference_mismatch")
    assert_equal "ignored", receipt.status
    assert_equal original_attributes, subscription_state(account.subscription.reload)
    assert_equal "open", attempt.reload.status
  end

  test "cross-account Stripe Customer reuse is rejected before canonical retrieval" do
    account = create_account(name: "Canonical Cross Account Target")
    other_account = create_account(name: "Canonical Cross Account Existing")
    other_account.subscription.update!(
      provider: "stripe",
      external_customer_id: "cus_cross_account_canonical"
    )
    attempt = create_checkout_attempt(account: account, customer_id: "cus_cross_account_canonical")
    original_attributes = subscription_state(account.subscription)
    event_data = subscription_data(
      attempt: attempt,
      account_reference: Billing::StripeAccountReference.generate(account),
      customer_id: "cus_cross_account_canonical",
      subscription_id: "sub_cross_account_canonical",
      status: "trialing"
    )
    retrieve_count = 0

    with_stripe_subscription_retrieve(->(*) { retrieve_count += 1 }) do
      post_signed_event(
        event_id: "evt_cross_account_canonical",
        event_type: "customer.subscription.created",
        data_object: event_data,
        canonical_subscription: nil
      )
    end

    assert_response :success
    receipt = BillingWebhookEvent.find_by!(external_event_id: "evt_cross_account_canonical")
    assert_equal "ignored", receipt.status
    assert_equal 0, retrieve_count
    assert_equal original_attributes, subscription_state(account.subscription.reload)
    assert_equal "open", attempt.reload.status
  end

  test "deferred and Checkout completion events do not retrieve a Stripe Subscription" do
    account = create_account(name: "No Lifecycle Retrieval")
    attempt = create_checkout_attempt(
      account: account,
      customer_id: "cus_no_lifecycle_retrieval",
      session_id: "cs_no_lifecycle_retrieval"
    )

    with_stripe_subscription_retrieve(->(*) { flunk("Subscription retrieval was unexpected") }) do
      post_signed_event(
        event_id: "evt_no_retrieval_checkout",
        event_type: "checkout.session.completed",
        data_object: checkout_session_data(
          attempt: attempt,
          account_reference: Billing::StripeAccountReference.generate(account),
          customer_id: "cus_no_lifecycle_retrieval",
          subscription_id: "sub_no_lifecycle_retrieval"
        )
      )
      assert_response :success

      post_signed_event(event_id: "evt_no_retrieval_deferred", event_type: "invoice.payment_succeeded")
      assert_response :success
    end
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
      livemode: false,
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
    assert_includes log_output, "livemode=false"
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
    payload = stripe_event_payload(event_id: "evt_duplicate", event_type: "invoice.payment_succeeded")
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
    payload = stripe_event_payload(event_id: "evt_retry_after_failure", event_type: "invoice.payment_succeeded")
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
    payload = stripe_event_payload(event_id: "evt_repeated_failure", event_type: "invoice.payment_succeeded")
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
      event_type: "invoice.payment_succeeded",
      livemode: false,
      status: "failed",
      failed_at: 1.hour.ago,
      error_code: "RuntimeError"
    )
    payload = stripe_event_payload(event_id: "evt_race_failed", event_type: "invoice.payment_succeeded")
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
      post_signed_event(event_id: "evt_dispatch_failure", event_type: "invoice.payment_succeeded")
    end

    assert_response :internal_server_error
    receipt = BillingWebhookEvent.find_by!(provider: "stripe", external_event_id: "evt_dispatch_failure")
    assert_equal "failed", receipt.status
    assert_equal "RuntimeError", receipt.error_code
    assert receipt.failed_at.present?
    assert_not_includes response.body, "synthetic failure"
  end

  test "unknown webhook events do not change local subscription lifecycle state" do
    account = create_account(name: "Stripe Foundation Owner")
    original_attributes = account.subscription.attributes.slice("plan", "status", "provider", "external_customer_id", "external_subscription_id")

    post_signed_event(event_id: "evt_no_subscription_sync", event_type: "customer.created")
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
    api_version: "2026-07-01", data_object: nil, event_created: Time.current.to_i,
    canonical_subscription: EVENT_DATA_AS_CANONICAL)
    payload = stripe_event_payload(
      event_id: event_id,
      event_type: event_type,
      livemode: livemode,
      api_version: api_version,
      data_object: data_object,
      event_created: event_created
    )
    request = -> { post webhooks_stripe_path, params: payload, headers: stripe_signature_headers(payload) }
    unless subscription_lifecycle_event?(event_type) && data_object
      return request.call
    end
    return request.call if canonical_subscription.nil?

    canonical_data = canonical_subscription.equal?(EVENT_DATA_AS_CANONICAL) ? data_object : canonical_subscription
    expected_subscription_id = data_object[:id] || data_object["id"]
    with_stripe_subscription_retrieve(
      ->(subscription_id, options) {
        assert_equal expected_subscription_id, subscription_id
        assert_equal Rails.configuration.x.stripe.secret_key, options.fetch(:api_key)
        stripe_subscription(canonical_data)
      },
      &request
    )
  end

  def subscription_lifecycle_event?(event_type)
    %w[customer.subscription.created customer.subscription.updated].include?(event_type)
  end

  def stripe_subscription(data)
    Stripe::Subscription.construct_from(data)
  end

  def with_stripe_subscription_retrieve(replacement)
    original_method = Stripe::Subscription.method(:retrieve)
    Stripe::Subscription.define_singleton_method(:retrieve) do |*args, **kwargs|
      replacement.call(*args, **kwargs)
    end

    yield
  ensure
    Stripe::Subscription.define_singleton_method(:retrieve, original_method)
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
    option_key: "self_managed_monthly", status: "open", replaces_external_subscription_id: nil)
    BillingCheckoutAttempt.create!(
      account: account,
      option_key: option_key,
      stripe_customer_id: customer_id,
      stripe_checkout_session_id: session_id,
      idempotency_key: SecureRandom.uuid,
      replaces_external_subscription_id:,
      status: status
    )
  end

  def configure_terminal_subscription(account, customer_id:, subscription_id:, ended_at:)
    account.subscription.update!(
      provider: "stripe",
      plan: "self_managed",
      status: "canceled",
      external_customer_id: customer_id,
      external_subscription_id: subscription_id,
      current_period_ends_at: ended_at,
      canceled_at: ended_at,
      entitlement_ended_at: ended_at,
      last_synced_at: ended_at
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
      "cancel_at",
      "canceled_at",
      "entitlement_ended_at",
      "past_due_observed_at",
      "last_synced_at"
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
