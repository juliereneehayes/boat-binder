class Subscription < ApplicationRecord
  LOCAL_PROVIDER = "local"
  STRIPE_PROVIDER = "stripe"
  PROVIDERS = [ LOCAL_PROVIDER, STRIPE_PROVIDER ].freeze
  PLANS = %w[legacy self_managed starter professional].freeze
  PENDING_CHECKOUT_STATUS = "pending_checkout"
  STATUSES = [ "legacy", PENDING_CHECKOUT_STATUS, "trialing", "active", "past_due", "canceled", "expired", "suspended" ].freeze

  belongs_to :account

  validates :account_id, uniqueness: true
  validates :plan, inclusion: { in: PLANS }
  validates :status, inclusion: { in: STATUSES }
  validates :provider, inclusion: { in: PROVIDERS }
  validates :external_subscription_id, uniqueness: { scope: :provider }, allow_nil: true
  validate :owner_user_limit_allows_plan

  scope :managed_externally, -> { where.not(provider: LOCAL_PROVIDER) }

  def self.default_local_attributes
    {
      plan: "legacy",
      status: "active",
      provider: LOCAL_PROVIDER
    }
  end

  def self.pending_checkout_attributes
    {
      provider: LOCAL_PROVIDER,
      plan: Billing::SubscriptionPlanCatalog::SELF_MANAGED_PLAN_KEY,
      status: PENDING_CHECKOUT_STATUS
    }
  end

  def pending_checkout?
    self.class.pending_checkout_attributes.all? do |attribute, expected_value|
      public_send(attribute) == expected_value
    end
  end

  def active?
    status == "active"
  end

  def trialing?
    status == "trialing"
  end

  def past_due?
    status == "past_due"
  end

  def canceled?
    status == "canceled"
  end

  def scheduled_cancellation_at
    cancel_at || (current_period_ends_at if cancel_at_period_end?)
  end

  def scheduled_cancellation?(now: Time.current)
    (active? || trialing?) && scheduled_cancellation_at&.>(now)
  end

  def expired?
    status == "expired"
  end

  def suspended?
    status == "suspended"
  end

  def managed_externally?
    provider != LOCAL_PROVIDER
  end

  def plan_label
    plan.to_s.humanize
  end

  def status_label
    status.to_s.humanize
  end

  def provider_label
    provider.to_s.humanize
  end

  private

  def owner_user_limit_allows_plan
    return unless will_save_change_to_plan?
    return unless plan == Billing::SubscriptionPlanCatalog::SELF_MANAGED_PLAN_KEY && account_id.present?

    # Active Record's save transaction includes validations, so this lock remains
    # held through the Subscription plan UPDATE.
    Account.transaction do
      locked_account = Account.lock.find(account_id)
      return if Billing::OwnerUserLimit.compliant_for_plan?(locked_account, plan_key: plan)

      errors.add(:plan, Billing::OwnerUserLimit::ERROR_MESSAGE)
    end
  end
end
