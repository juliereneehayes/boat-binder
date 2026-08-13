class Subscription < ApplicationRecord
  LOCAL_PROVIDER = "local"
  STRIPE_PROVIDER = "stripe"
  PROVIDERS = [ LOCAL_PROVIDER, STRIPE_PROVIDER ].freeze
  PLANS = %w[legacy self_managed starter professional].freeze
  STATUSES = %w[legacy trialing active past_due canceled expired suspended].freeze
  ACCESS_ALLOWED_STATUSES = %w[legacy trialing active].freeze

  belongs_to :account

  validates :account_id, uniqueness: true
  validates :plan, inclusion: { in: PLANS }
  validates :status, inclusion: { in: STATUSES }
  validates :provider, inclusion: { in: PROVIDERS }
  validates :external_subscription_id, uniqueness: { scope: :provider }, allow_nil: true

  scope :access_allowed, -> { where(status: ACCESS_ALLOWED_STATUSES) }
  scope :managed_externally, -> { where.not(provider: LOCAL_PROVIDER) }

  def self.default_local_attributes
    {
      plan: "legacy",
      status: "active",
      provider: LOCAL_PROVIDER
    }
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

  def expired?
    status == "expired"
  end

  def suspended?
    status == "suspended"
  end

  def access_allowed?
    ACCESS_ALLOWED_STATUSES.include?(status)
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
end
