require "test_helper"

class TrialStartConfirmationMailerTest < ActionMailer::TestCase
  setup do
    @previous_monthly_price_id = Rails.configuration.x.stripe.self_managed_monthly_price_id
    @previous_annual_price_id = Rails.configuration.x.stripe.self_managed_annual_price_id
    Rails.configuration.x.stripe.self_managed_monthly_price_id = "price_mail_monthly"
    Rails.configuration.x.stripe.self_managed_annual_price_id = "price_mail_annual"
    @account = create_account(name: "Private Customer Account", time_zone: "America/Los_Angeles")
  end

  teardown do
    Rails.configuration.x.stripe.self_managed_monthly_price_id = @previous_monthly_price_id
    Rails.configuration.x.stripe.self_managed_annual_price_id = @previous_annual_price_id
  end

  test "monthly confirmation is multipart and uses catalog pricing and account-local trial date" do
    confirmation = build_confirmation(
      option_key: Billing::SubscriptionPlanCatalog::SELF_MANAGED_MONTHLY_KEY,
      trial_ends_at: Time.utc(2026, 9, 17, 2)
    )
    mail = TrialStartConfirmationMailer.confirmation(confirmation, "verified-owner@example.test")

    assert mail.multipart?
    assert_equal [ "verified-owner@example.test" ], mail.to
    assert_equal "Your Boat Binder Self Managed trial has started", mail.subject
    assert_mail_parts_include mail, "Monthly", "$24/month", "Sep 16, 2026"
  end

  test "annual confirmation uses catalog pricing and contains safe billing direction" do
    confirmation = build_confirmation(
      option_key: Billing::SubscriptionPlanCatalog::SELF_MANAGED_ANNUAL_KEY
    )
    mail = TrialStartConfirmationMailer.confirmation(confirmation, "verified-owner@example.test")

    assert mail.multipart?
    assert_mail_parts_include mail, "Annual", "$240/year", "Manage billing", "http://example.com"
  end

  test "confirmation omits Stripe identifiers internal IDs and protected account content" do
    confirmation = build_confirmation
    mail = TrialStartConfirmationMailer.confirmation(confirmation, "verified-owner@example.test")
    rendered = [ mail.subject, mail.html_part.decoded, mail.text_part.decoded ].join(" ")

    assert_not_includes rendered, confirmation.external_subscription_id
    assert_not_includes rendered, "cus_private_customer"
    assert_not_includes rendered, "evt_private_webhook"
    assert_not_includes rendered, @account.name
    assert_not_includes rendered, "Private vessel document"
  end

  private

  def build_confirmation(option_key: Billing::SubscriptionPlanCatalog::SELF_MANAGED_MONTHLY_KEY,
    trial_ends_at: Time.utc(2026, 9, 16, 19))
    BillingTrialStartConfirmation.new(
      account: @account,
      subscription: @account.subscription,
      external_subscription_id: "sub_private_subscription",
      option_key:,
      trial_started_at: trial_ends_at - 7.days,
      trial_ends_at:
    )
  end

  def assert_mail_parts_include(mail, *values)
    values.each do |value|
      assert_includes mail.html_part.decoded, value
      assert_includes mail.text_part.decoded, value
    end
  end
end
