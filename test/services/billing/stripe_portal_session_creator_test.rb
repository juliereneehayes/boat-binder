require "test_helper"

module Billing
  class StripePortalSessionCreatorTest < ActiveSupport::TestCase
    SECRET_KEY = "sk_test_portal"
    CONFIGURATION_ID = "bpc_test_portal"
    RETURN_URL = "https://app.example.test/"

    setup do
      @now = Time.zone.local(2026, 8, 28, 12)
      @account = create_account(name: "Portal Service Owner")
      qualify_self_managed_subscription(@account, now: @now)

      @previous_secret_key = Rails.configuration.x.stripe.secret_key
      @previous_livemode = Rails.configuration.x.stripe.livemode
      @previous_configuration_id = Rails.configuration.x.stripe.billing_portal_configuration_id
      Rails.configuration.x.stripe.secret_key = SECRET_KEY
      Rails.configuration.x.stripe.livemode = false
      Rails.configuration.x.stripe.billing_portal_configuration_id = CONFIGURATION_ID
    end

    teardown do
      Rails.configuration.x.stripe.secret_key = @previous_secret_key
      Rails.configuration.x.stripe.livemode = @previous_livemode
      Rails.configuration.x.stripe.billing_portal_configuration_id = @previous_configuration_id
    end

    test "creates a configured Portal session for the verified existing Customer without local mutation" do
      request = nil
      original_subscription = subscription_state
      original_counts = record_counts

      travel_to @now do
        session = portal_session
        with_portal_create(->(params, options) {
          request = [ params, options ]
          session
        }) do
          assert_equal "bps_test_portal", create_portal_session.id
        end
      end

      params, options = request
      assert_equal @account.subscription.external_customer_id, params.fetch(:customer)
      assert_equal CONFIGURATION_ID, params.fetch(:configuration)
      assert_equal RETURN_URL, params.fetch(:return_url)
      assert_equal SECRET_KEY, options.fetch(:api_key)
      assert_equal original_subscription, subscription_state
      assert_equal original_counts, record_counts
    end

    test "accepts the documented Portal path and bounded slash paths" do
      valid_urls = [
        "https://billing.stripe.com/p/session?secret=test_portal_secret",
        "https://billing.stripe.com/p/session/test_portal_secret"
      ]

      travel_to @now do
        valid_urls.each do |url|
          session = portal_session(url:)

          with_portal_create(->(*) { session }) do
            assert_equal url, create_portal_session.url
          end
        end
      end
    end

    test "accepts active trialing scheduled cancellation and payment recovery phases" do
      configurations = [
        { status: "active", current_period_ends_at: @now + 1.month },
        { status: "trialing", trial_ends_at: @now + 7.days },
        {
          status: "active",
          current_period_ends_at: @now + 1.month,
          cancel_at_period_end: true
        },
        { status: "past_due" }
      ]

      travel_to @now do
        configurations.each do |attributes|
          configure_verified_subscription(**attributes)
          session = portal_session

          with_portal_create(->(*) { session }) do
            assert StripePortalSessionCreator.eligible_account?(@account)
            assert_equal "bps_test_portal", create_portal_session.id
          end
        end
      end
    end

    test "rejects inactive non-client and unsupported subscription states before Stripe is called" do
      assertions = [
        -> { @account.update!(active: false) },
        -> { @account.update!(active: true, account_type: "internal") },
        -> { @account.update!(account_type: "client"); @account.subscription.update!(provider: "local") },
        -> { configure_verified_subscription; @account.subscription.update!(plan: "professional") },
        -> { configure_verified_subscription; @account.subscription.update!(last_synced_at: nil) },
        -> { configure_verified_subscription; @account.subscription.update!(status: "suspended") },
        -> { configure_verified_subscription; @account.subscription.update!(status: "canceled") }
      ]

      travel_to @now do
        assertions.each do |configure|
          configure.call

          with_portal_create(->(*) { flunk("ineligible accounts must not call Stripe") }) do
            assert_not StripePortalSessionCreator.eligible_account?(@account)
            assert_raises(StripePortalSessionCreator::InvalidAccountError) { create_portal_session }
          end
        end
      end
    end

    test "rejects an existing over-limit Account before Stripe is called" do
      first = create_user(email: "portal-service-owner-one@example.test", role: "owner")
      second = create_user(email: "portal-service-owner-two@example.test", role: "owner")
      now = Time.current
      AccountMembership.insert_all!([
        {
          account_id: @account.id,
          user_id: first.id,
          access_level: "editor",
          active: true,
          created_at: now,
          updated_at: now
        },
        {
          account_id: @account.id,
          user_id: second.id,
          access_level: "read_only",
          active: true,
          created_at: now,
          updated_at: now
        }
      ])

      travel_to @now do
        with_portal_create(->(*) { flunk("over-limit accounts must not call Stripe") }) do
          assert_not StripePortalSessionCreator.eligible_account?(@account.reload)
          assert_raises(StripePortalSessionCreator::InvalidAccountError) { create_portal_session }
        end
      end
    end

    test "requires explicit Portal configuration mode and API key before calling Stripe" do
      settings = [
        [ :billing_portal_configuration_id, nil ],
        [ :livemode, nil ],
        [ :secret_key, nil ]
      ]

      travel_to @now do
        settings.each do |name, value|
          previous = Rails.configuration.x.stripe.public_send(name)
          Rails.configuration.x.stripe.public_send("#{name}=", value)

          with_portal_create(->(*) { flunk("missing configuration must not call Stripe") }) do
            assert_raises(StripeConfiguration::MissingConfigurationError) { create_portal_session }
          end
        ensure
          Rails.configuration.x.stripe.public_send("#{name}=", previous)
        end
      end
    end

    test "rejects mismatched session identity mode return URL and unsafe destinations" do
      invalid_sessions = [
        nil,
        Object.new,
        portal_session(customer: "cus_other"),
        portal_session(configuration: "bpc_other"),
        portal_session(livemode: true),
        portal_session(return_url: "https://attacker.example/"),
        portal_session(url: "http://billing.stripe.com/p/session?secret=test_portal_secret"),
        portal_session(url: "https://attacker.example/p/session?secret=test_portal_secret"),
        portal_session(url: "https://subdomain.billing.stripe.com/p/session?secret=test_portal_secret"),
        portal_session(url: "https://billing.stripe.com:444/p/session?secret=test_portal_secret"),
        portal_session(url: "https://user@billing.stripe.com/p/session?secret=test_portal_secret"),
        portal_session(url: "https://billing.stripe.com/p/session-attacker?secret=test_portal_secret"),
        portal_session(url: "https://billing.stripe.com/p/session.evil?secret=test_portal_secret"),
        portal_session(url: "https://billing.stripe.com/not-a-session"),
        portal_session(url: "not a URL")
      ]

      travel_to @now do
        invalid_sessions.each do |session|
          with_portal_create(->(*) { session }) do
            assert_raises(StripePortalSessionCreator::InvalidSessionError) { create_portal_session }
          end
        end
      end
    end

    test "wraps Stripe failures without exposing the provider message" do
      error = Stripe::APIConnectionError.new("private provider detail")
      log_output = StringIO.new
      logger = ActiveSupport::Logger.new(log_output)
      exception = nil

      travel_to @now do
        with_portal_create(->(*) { raise error }) do
          with_singleton_method(Rails, :logger, -> { logger }) do
            exception = assert_raises(StripePortalSessionCreator::PortalError) { create_portal_session }
          end
        end
      end

      assert_equal "Stripe Billing Portal could not be opened", exception.message
      assert_includes log_output.string, "Stripe::APIConnectionError"
      assert_not_includes log_output.string, "private provider detail"
    end

    private

    def create_portal_session
      StripePortalSessionCreator.call(account: @account, return_url: RETURN_URL)
    end

    def portal_session(customer: @account.subscription.external_customer_id,
      configuration: CONFIGURATION_ID, livemode: false, return_url: RETURN_URL,
      url: "https://billing.stripe.com/p/session?secret=test_portal_secret")
      Stripe::BillingPortal::Session.construct_from(
        id: "bps_test_portal",
        customer:,
        configuration:,
        livemode:,
        return_url:,
        url:
      )
    end

    def configure_verified_subscription(**attributes)
      qualify_self_managed_subscription(@account, now: @now)
      @account.subscription.update!(attributes)
    end

    def with_portal_create(replacement)
      with_singleton_method(Stripe::BillingPortal::Session, :create, replacement) { yield }
    end

    def with_singleton_method(receiver, method_name, replacement)
      original = receiver.method(method_name)
      receiver.define_singleton_method(method_name, replacement)
      yield
    ensure
      receiver.define_singleton_method(method_name, original)
    end

    def subscription_state
      @account.subscription.reload.attributes.except("created_at", "updated_at")
    end

    def record_counts
      [ Account.count, Subscription.count, BillingCheckoutAttempt.count ]
    end
  end
end
