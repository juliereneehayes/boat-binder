require "test_helper"

class StripeSubscriptionLifecycleTest < ActionDispatch::IntegrationTest
  WEBHOOK_SECRET = "whsec_lifecycle_test"

  setup do
    @previous_secret_key = Rails.configuration.x.stripe.secret_key
    @previous_webhook_secret = Rails.configuration.x.stripe.webhook_secret
    @previous_livemode = Rails.configuration.x.stripe.livemode
    @previous_monthly_price_id = Rails.configuration.x.stripe.self_managed_monthly_price_id
    @previous_annual_price_id = Rails.configuration.x.stripe.self_managed_annual_price_id
    Rails.configuration.x.stripe.secret_key = "sk_test_lifecycle"
    Rails.configuration.x.stripe.webhook_secret = WEBHOOK_SECRET
    Rails.configuration.x.stripe.livemode = false
    Rails.configuration.x.stripe.self_managed_monthly_price_id = "price_lifecycle_monthly"
    Rails.configuration.x.stripe.self_managed_annual_price_id = "price_lifecycle_annual"
  end

  teardown do
    Rails.configuration.x.stripe.secret_key = @previous_secret_key
    Rails.configuration.x.stripe.webhook_secret = @previous_webhook_secret
    Rails.configuration.x.stripe.livemode = @previous_livemode
    Rails.configuration.x.stripe.self_managed_monthly_price_id = @previous_monthly_price_id
    Rails.configuration.x.stripe.self_managed_annual_price_id = @previous_annual_price_id
  end

  test "all supported canonical Stripe statuses map to the deliberate local states" do
    expected_statuses = {
      "trialing" => "trialing",
      "active" => "active",
      "past_due" => "past_due",
      "canceled" => "canceled",
      "incomplete" => "suspended",
      "unpaid" => "suspended",
      "paused" => "suspended",
      "incomplete_expired" => "expired"
    }

    expected_statuses.each_with_index do |(stripe_status, local_status), index|
      state = create_stripe_state("status_#{index}")
      canonical = subscription_data(state:, status: stripe_status)

      post_lifecycle_event(
        event_id: "evt_status_#{stripe_status}",
        event_type: "customer.subscription.updated",
        data_object: canonical,
        canonical_subscription: canonical
      )

      assert_response :success
      assert_equal local_status, state.fetch(:subscription).reload.status
      assert_equal "processed", receipt("evt_status_#{stripe_status}").status
    end
  end

  test "invoice paid renews the existing subscription and payment failure and recovery use canonical state" do
    state = create_stripe_state("invoice_lifecycle", status: "trialing")
    subscription_id = state.fetch(:subscription_id)
    local_subscription_id = state.fetch(:subscription).id
    renewed_period_end = 1.year.from_now.change(usec: 0)

    post_invoice_event(
      state:,
      event_id: "evt_invoice_paid_renewal",
      event_type: "invoice.paid",
      canonical_status: "active",
      period_end: renewed_period_end
    )

    assert_response :success
    subscription = state.fetch(:subscription).reload
    assert_equal local_subscription_id, subscription.id
    assert_equal subscription_id, subscription.external_subscription_id
    assert_equal "active", subscription.status
    assert_equal renewed_period_end.to_i, subscription.current_period_ends_at.to_i
    assert_equal 1, Subscription.where(account: state.fetch(:account)).count

    first_observed_at = Time.zone.local(2026, 8, 25, 12)
    travel_to first_observed_at do
      post_invoice_event(
        state:,
        event_id: "evt_invoice_payment_failed",
        event_type: "invoice.payment_failed",
        canonical_status: "past_due"
      )
    end

    assert_response :success
    assert_equal "past_due", subscription.reload.status
    assert_equal first_observed_at, subscription.past_due_observed_at

    travel_to first_observed_at + 1.hour do
      post_invoice_event(
        state:,
        event_id: "evt_invoice_payment_still_failed",
        event_type: "invoice.payment_failed",
        canonical_status: "past_due"
      )
    end

    assert_response :success
    assert_equal first_observed_at, subscription.reload.past_due_observed_at

    post_invoice_event(
      state:,
      event_id: "evt_invoice_paid_recovery",
      event_type: "invoice.paid",
      canonical_status: "active"
    )

    assert_response :success
    assert_equal "active", subscription.reload.status
    assert_nil subscription.past_due_observed_at
  end

  test "verified trial transition persists its canonical ending boundary without fabricating a new trial" do
    state = create_stripe_state("trial_ended", status: "trialing")
    trial_end = Time.zone.local(2026, 8, 25, 12)

    travel_to trial_end + 1.second do
      post_subscription_event(
        state:,
        event_id: "evt_trial_ended_paused",
        event_type: "customer.subscription.paused",
        status: "paused",
        trial_end:
      )
    end

    subscription = state.fetch(:subscription).reload
    entitlement = Billing::SelfManagedEntitlement.new(account: state.fetch(:account).reload, now: trial_end + 1.second)
    assert_equal "suspended", subscription.status
    assert_equal trial_end, subscription.entitlement_ended_at
    assert_equal trial_end, entitlement.entitlement_ended_at
    assert_equal :verified_lifecycle_end, entitlement.entitlement_end_reason
    assert_equal 1, Subscription.where(account: state.fetch(:account)).count
  end

  test "scheduled cancellation reversal pause resume and final deletion follow canonical state" do
    state = create_stripe_state("subscription_lifecycle")
    account = state.fetch(:account)
    vessel = create_vessel(account:, name: "Lifecycle Vessel")
    owner = create_user(email: "lifecycle-owner@example.test", role: "owner")
    membership = create_account_membership(user: owner, account:, access_level: "editor")
    document = vessel.documents.create!(account:, title: "Lifecycle document", document_type: "other")
    document.file.attach(fixture_file_upload("sample.pdf", "application/pdf"))
    vessel.primary_photo.attach(fixture_file_upload("sample.jpg", "image/jpeg"))
    note = vessel.binder_notes.create!(
      account:,
      title: "Lifecycle note",
      body: "Retain this note.",
      note_type: "general"
    )
    reminder = vessel.reminders.create!(
      title: "Lifecycle reminder",
      due_date: Date.tomorrow,
      reminder_type: "maintenance",
      status: "pending"
    )
    service_visit = ServiceVisit.create!(
      asset: vessel,
      performed_by_user: owner,
      visit_date: Date.current,
      summary: "Lifecycle visit"
    )
    period_end = 1.month.from_now.change(usec: 0)
    cancellation_requested_at = Time.current.change(usec: 0)

    post_subscription_event(
      state:,
      event_id: "evt_cancel_scheduled",
      event_type: "customer.subscription.updated",
      status: "active",
      period_end:,
      cancel_at_period_end: true,
      canceled_at: cancellation_requested_at
    )
    subscription = state.fetch(:subscription).reload
    assert subscription.cancel_at_period_end?
    assert_equal cancellation_requested_at, subscription.canceled_at
    assert_nil subscription.entitlement_ended_at

    post_subscription_event(
      state:,
      event_id: "evt_cancel_reversed",
      event_type: "customer.subscription.updated",
      status: "active",
      cancel_at_period_end: false
    )
    assert_not state.fetch(:subscription).reload.cancel_at_period_end?

    post_subscription_event(
      state:,
      event_id: "evt_subscription_paused",
      event_type: "customer.subscription.paused",
      status: "paused"
    )
    assert_equal "suspended", state.fetch(:subscription).reload.status

    post_subscription_event(
      state:,
      event_id: "evt_subscription_resumed",
      event_type: "customer.subscription.resumed",
      status: "active"
    )
    assert_equal "active", state.fetch(:subscription).reload.status

    ended_at = Time.current.change(usec: 0)
    post_subscription_event(
      state:,
      event_id: "evt_subscription_deleted",
      event_type: "customer.subscription.deleted",
      status: "canceled",
      period_end:,
      canceled_at: ended_at,
      ended_at:
    )

    subscription = state.fetch(:subscription).reload
    assert_equal "canceled", subscription.status
    assert_equal ended_at.to_i, subscription.canceled_at.to_i
    assert_equal ended_at.to_i, subscription.entitlement_ended_at.to_i
    assert_equal state.fetch(:customer_id), subscription.external_customer_id
    assert_equal state.fetch(:subscription_id), subscription.external_subscription_id
    assert Account.exists?(account.id)
    assert Asset.exists?(vessel.id)
    assert AccountMembership.exists?(membership.id)
    assert Document.exists?(document.id)
    assert BinderNote.exists?(note.id)
    assert Reminder.exists?(reminder.id)
    assert ServiceVisit.exists?(service_visit.id)
    assert document.reload.file.attached?
    assert vessel.reload.primary_photo.attached?
  end

  test "terminal canonical state does not fabricate former entitlement without verified local history" do
    state = create_stripe_state("unverified_terminal")
    state.fetch(:subscription).update!(plan: "legacy", last_synced_at: nil)
    ended_at = 1.hour.ago.change(usec: 0)

    post_subscription_event(
      state:,
      event_id: "evt_unverified_terminal",
      event_type: "customer.subscription.deleted",
      status: "canceled",
      ended_at:
    )

    subscription = state.fetch(:subscription).reload
    entitlement = Billing::SelfManagedEntitlement.new(account: state.fetch(:account).reload)
    assert_equal "canceled", subscription.status
    assert_nil subscription.entitlement_ended_at
    assert_nil entitlement.entitlement_ended_at
    assert_equal :entitlement_end_unavailable, entitlement.entitlement_end_reason
  end

  test "delayed event snapshots converge on canonical ending boundary without rewinding it" do
    state = create_stripe_state("canonical_end_order")
    ended_at = 1.hour.ago.change(usec: 0)
    canonical = subscription_data(state:, status: "canceled", ended_at:)
    stale_snapshot = subscription_data(state:, status: "active", period_end: 1.month.from_now)

    post_lifecycle_event(
      event_id: "evt_delayed_active_snapshot",
      event_type: "customer.subscription.updated",
      data_object: stale_snapshot,
      canonical_subscription: canonical
    )
    assert_response :success
    assert_equal ended_at, state.fetch(:subscription).reload.entitlement_ended_at

    canonical[:ended_at] = (ended_at - 1.day).to_i
    post_lifecycle_event(
      event_id: "evt_delayed_canceled_snapshot",
      event_type: "customer.subscription.deleted",
      data_object: subscription_data(state:, status: "canceled", ended_at: ended_at - 1.day),
      canonical_subscription: canonical
    )

    assert_response :success
    assert_equal ended_at, state.fetch(:subscription).reload.entitlement_ended_at
    assert_equal 1, Subscription.where(account: state.fetch(:account)).count
  end

  test "invoice association mismatches and missing correlation fail closed" do
    scenarios = {
      "customer mismatch" => ->(invoice, _state) { invoice[:customer] = "cus_wrong" },
      "subscription mismatch" => lambda { |invoice, _state|
        invoice[:parent][:subscription_details][:subscription] = "sub_wrong"
      },
      "missing metadata" => ->(invoice, _state) { invoice[:parent][:subscription_details][:metadata] = {} },
      "invalid account reference" => lambda { |invoice, _state|
        invoice[:parent][:subscription_details][:metadata][account_reference_key] = "tampered-account-reference"
      },
      "invalid attempt reference" => lambda { |invoice, _state|
        invoice[:parent][:subscription_details][:metadata][attempt_reference_key] = "tampered-attempt-reference"
      },
      "another account reference" => lambda { |invoice, _state|
        other_account = create_account(name: "Other Invoice Account #{SecureRandom.hex(4)}")
        invoice[:parent][:subscription_details][:metadata][account_reference_key] =
          Billing::StripeAccountReference.generate(other_account)
      }
    }

    scenarios.each_with_index do |(name, mutate), index|
      state = create_stripe_state("invoice_rejected_#{index}")
      original_state = subscription_state(state.fetch(:subscription))
      invoice = invoice_data(state:, invoice_id: "in_rejected_#{index}")
      mutate.call(invoice, state)
      retrieve_count = 0

      with_stripe_subscription_retrieve(->(*) { retrieve_count += 1 }) do
        post_signed_event(
          event_id: "evt_invoice_rejected_#{index}",
          event_type: "invoice.paid",
          data_object: invoice
        )
      end

      assert_response :success, name
      assert_equal "ignored", receipt("evt_invoice_rejected_#{index}").status, name
      assert_equal original_state, subscription_state(state.fetch(:subscription).reload), name
      assert_equal 0, retrieve_count, name
    end
  end

  test "invoice with an unknown canonical Price fails closed without mutation" do
    state = create_stripe_state("unknown_invoice_price")
    invoice = invoice_data(state:, invoice_id: "in_unknown_price")
    canonical = subscription_data(state:, status: "active", price_id: "price_unknown")
    original_state = subscription_state(state.fetch(:subscription))

    post_lifecycle_event(
      event_id: "evt_invoice_unknown_price",
      event_type: "invoice.paid",
      data_object: invoice,
      canonical_subscription: canonical
    )

    assert_response :success
    assert_equal "ignored", receipt("evt_invoice_unknown_price").status
    assert_equal original_state, subscription_state(state.fetch(:subscription).reload)
  end

  test "unsupported canonical status is processed into a conservative suspended state" do
    state = create_stripe_state("unsupported_status")
    canonical = subscription_data(state:, status: "future_status")

    log_output = capture_rails_logs do
      post_lifecycle_event(
        event_id: "evt_unsupported_status",
        event_type: "customer.subscription.updated",
        data_object: canonical,
        canonical_subscription: canonical
      )
    end

    assert_response :success
    assert_equal "processed", receipt("evt_unsupported_status").status
    subscription = state.fetch(:subscription).reload
    assert_equal "suspended", subscription.status
    entitlement = Billing::SelfManagedEntitlement.new(account: state.fetch(:account).reload)
    assert_not entitlement.qualifying?
    assert_equal :non_qualifying_status, entitlement.reason
    assert_equal state.fetch(:account).id, subscription.account_id
    assert_equal state.fetch(:customer_id), subscription.external_customer_id
    assert_equal state.fetch(:subscription_id), subscription.external_subscription_id
    assert_includes log_output, "reason=unsupported_subscription_status"
    assert_not_includes log_output, "future_status"
  end

  test "mode mismatch is ignored before retrieval and cannot mutate either environment" do
    state = create_stripe_state("mode_isolation")
    canonical = subscription_data(state:, status: "active")
    original_state = subscription_state(state.fetch(:subscription))
    retrieve_count = 0

    with_stripe_subscription_retrieve(->(*) { retrieve_count += 1 }) do
      post_signed_event(
        event_id: "evt_live_into_test",
        event_type: "customer.subscription.updated",
        livemode: true,
        data_object: canonical
      )
    end

    assert_response :success
    assert_equal "ignored", receipt("evt_live_into_test").status
    assert_equal 0, retrieve_count
    assert_equal original_state, subscription_state(state.fetch(:subscription).reload)

    Rails.configuration.x.stripe.livemode = true
    with_stripe_subscription_retrieve(->(*) { retrieve_count += 1 }) do
      post_signed_event(
        event_id: "evt_test_into_live",
        event_type: "customer.subscription.updated",
        livemode: false,
        data_object: canonical
      )
    end

    assert_response :success
    assert_equal "ignored", receipt("evt_test_into_live").status
    assert_equal 0, retrieve_count
    assert_equal original_state, subscription_state(state.fetch(:subscription).reload)
  end

  test "missing expected mode is retryable and does not mutate state" do
    state = create_stripe_state("missing_mode")
    canonical = subscription_data(state:, status: "active")
    original_state = subscription_state(state.fetch(:subscription))
    Rails.configuration.x.stripe.livemode = nil

    post_signed_event(
      event_id: "evt_missing_expected_mode",
      event_type: "customer.subscription.updated",
      data_object: canonical
    )

    assert_response :internal_server_error
    assert_equal "failed", receipt("evt_missing_expected_mode").status
    assert_equal original_state, subscription_state(state.fetch(:subscription).reload)
  end

  test "duplicate invoice delivery is idempotent and does not retrieve twice" do
    state = create_stripe_state("duplicate_invoice")
    invoice = invoice_data(state:, invoice_id: "in_duplicate")
    canonical = subscription_data(state:, status: "past_due")
    payload = event_payload(
      event_id: "evt_duplicate_invoice",
      event_type: "invoice.paid",
      data_object: invoice
    )
    retrieve_count = 0

    observed_at = Time.zone.local(2026, 8, 25, 14)
    travel_to observed_at do
      with_stripe_subscription_retrieve(lambda { |subscription_id, options|
        retrieve_count += 1
        assert_equal state.fetch(:subscription_id), subscription_id
        assert_equal Rails.configuration.x.stripe.secret_key, options.fetch(:api_key)
        Stripe::Subscription.construct_from(canonical)
      }) do
        2.times do
          post webhooks_stripe_path, params: payload, headers: signature_headers(payload)
          assert_response :success
        end
      end
    end

    assert_equal 1, retrieve_count
    assert_equal 1, BillingWebhookEvent.where(external_event_id: "evt_duplicate_invoice").count
    assert_equal "processed", receipt("evt_duplicate_invoice").status
    subscription = state.fetch(:subscription).reload
    assert_equal "past_due", subscription.status
    assert_equal observed_at, subscription.past_due_observed_at
  end

  test "Stripe retrieval failure remains retryable and a later delivery reconciles" do
    state = create_stripe_state("retry_invoice")
    invoice = invoice_data(state:, invoice_id: "in_retry")
    canonical = subscription_data(state:, status: "past_due")
    payload = event_payload(event_id: "evt_retry_invoice", event_type: "invoice.payment_failed", data_object: invoice)
    original_state = subscription_state(state.fetch(:subscription))

    with_stripe_subscription_retrieve(->(*) { raise Stripe::APIConnectionError, "temporary Stripe outage" }) do
      post webhooks_stripe_path, params: payload, headers: signature_headers(payload)
    end

    assert_response :internal_server_error
    assert_equal "failed", receipt("evt_retry_invoice").status
    assert_equal original_state, subscription_state(state.fetch(:subscription).reload)
    assert_nil state.fetch(:subscription).past_due_observed_at

    with_stripe_subscription_retrieve(->(*) { Stripe::Subscription.construct_from(canonical) }) do
      post webhooks_stripe_path, params: payload, headers: signature_headers(payload)
    end

    assert_response :success
    assert_equal "processed", receipt("evt_retry_invoice").status
    assert_equal "past_due", state.fetch(:subscription).reload.status
    assert state.fetch(:subscription).past_due_observed_at.present?
  end

  private

  def create_stripe_state(suffix, status: "active", option_key: "self_managed_monthly")
    account = create_account(name: "Lifecycle #{suffix}")
    customer_id = "cus_#{suffix}"
    subscription_id = "sub_#{suffix}"
    attempt = BillingCheckoutAttempt.create!(
      account:,
      option_key:,
      stripe_customer_id: customer_id,
      stripe_checkout_session_id: "cs_#{suffix}",
      idempotency_key: SecureRandom.uuid,
      status: "completed"
    )
    subscription = account.subscription
    subscription.update!(
      provider: "stripe",
      plan: "self_managed",
      status:,
      external_customer_id: customer_id,
      external_subscription_id: subscription_id,
      last_synced_at: 1.day.ago
    )

    { account:, attempt:, subscription:, customer_id:, subscription_id:, option_key: }
  end

  def post_invoice_event(state:, event_id:, event_type:, canonical_status:, period_end: 1.month.from_now)
    post_lifecycle_event(
      event_id:,
      event_type:,
      data_object: invoice_data(state:, invoice_id: "in_#{event_id}"),
      canonical_subscription: subscription_data(state:, status: canonical_status, period_end:)
    )
  end

  def post_subscription_event(state:, event_id:, event_type:, status:, **attributes)
    canonical = subscription_data(state:, status:, **attributes)
    post_lifecycle_event(
      event_id:,
      event_type:,
      data_object: canonical,
      canonical_subscription: canonical
    )
  end

  def post_lifecycle_event(event_id:, event_type:, data_object:, canonical_subscription:, livemode: false)
    expected_subscription_id = if event_type.start_with?("invoice.")
      data_object.dig(:parent, :subscription_details, :subscription)
    else
      data_object.fetch(:id)
    end

    with_stripe_subscription_retrieve(lambda { |subscription_id, options|
      assert_equal expected_subscription_id, subscription_id
      assert_equal Rails.configuration.x.stripe.secret_key, options.fetch(:api_key)
      Stripe::Subscription.construct_from(canonical_subscription)
    }) do
      post_signed_event(event_id:, event_type:, data_object:, livemode:)
    end
  end

  def post_signed_event(event_id:, event_type:, data_object:, livemode: false)
    payload = event_payload(event_id:, event_type:, data_object:, livemode:)
    post webhooks_stripe_path, params: payload, headers: signature_headers(payload)
  end

  def event_payload(event_id:, event_type:, data_object:, livemode: false)
    JSON.generate(
      id: event_id,
      object: "event",
      type: event_type,
      created: Time.current.to_i,
      livemode:,
      api_version: "2026-07-01",
      data: { object: data_object }
    )
  end

  def signature_headers(payload)
    timestamp = Time.current
    signature = Stripe::Webhook::Signature.compute_signature(timestamp, payload, WEBHOOK_SECRET)
    {
      "CONTENT_TYPE" => "application/json",
      "Stripe-Signature" => Stripe::Webhook::Signature.generate_header(timestamp, signature)
    }
  end

  def subscription_data(state:, status:, price_id: "price_lifecycle_monthly", period_end: 1.month.from_now,
    trial_end: status == "trialing" ? 7.days.from_now : nil,
    cancel_at_period_end: false, canceled_at: nil, ended_at: nil)
    {
      id: state.fetch(:subscription_id),
      object: "subscription",
      customer: state.fetch(:customer_id),
      status:,
      trial_end: trial_end&.to_i,
      cancel_at_period_end:,
      canceled_at: canceled_at&.to_i,
      ended_at: ended_at&.to_i,
      metadata: correlation_metadata(state),
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

  def invoice_data(state:, invoice_id:)
    {
      id: invoice_id,
      object: "invoice",
      customer: state.fetch(:customer_id),
      parent: {
        type: "subscription_details",
        subscription_details: {
          subscription: state.fetch(:subscription_id),
          metadata: correlation_metadata(state)
        }
      }
    }
  end

  def correlation_metadata(state)
    {
      account_reference_key => Billing::StripeAccountReference.generate(state.fetch(:account)),
      attempt_reference_key => Billing::StripeCheckoutAttemptReference.generate(state.fetch(:attempt)),
      option_key => state.fetch(:option_key)
    }
  end

  def account_reference_key
    Billing::StripeCheckoutSessionCreator::ACCOUNT_REFERENCE_KEY
  end

  def attempt_reference_key
    Billing::StripeCheckoutSessionCreator::ATTEMPT_REFERENCE_KEY
  end

  def option_key
    Billing::StripeCheckoutSessionCreator::OPTION_KEY
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

  def receipt(event_id)
    BillingWebhookEvent.find_by!(provider: "stripe", external_event_id: event_id)
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
      "entitlement_ended_at",
      "past_due_observed_at",
      "last_synced_at"
    )
  end
end
