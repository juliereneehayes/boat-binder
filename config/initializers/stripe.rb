Rails.application.config.x.stripe.secret_key =
  ENV["STRIPE_SECRET_KEY"].presence || Rails.application.credentials.dig(:stripe, :secret_key)
Rails.application.config.x.stripe.publishable_key =
  ENV["STRIPE_PUBLISHABLE_KEY"].presence || Rails.application.credentials.dig(:stripe, :publishable_key)
Rails.application.config.x.stripe.webhook_secret =
  ENV["STRIPE_WEBHOOK_SECRET"].presence || Rails.application.credentials.dig(:stripe, :webhook_secret)
Rails.application.config.x.stripe.self_managed_monthly_price_id =
  ENV["STRIPE_SELF_MANAGED_MONTHLY_PRICE_ID"].presence
Rails.application.config.x.stripe.self_managed_annual_price_id =
  ENV["STRIPE_SELF_MANAGED_ANNUAL_PRICE_ID"].presence

Stripe.api_key = Rails.application.config.x.stripe.secret_key if Rails.application.config.x.stripe.secret_key.present?
