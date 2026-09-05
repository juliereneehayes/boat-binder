class DashboardController < ApplicationController
  def index
    @owner_lifecycle_recoveries = owner_lifecycle_recoveries
    @reactivation_options = reactivation_options if @owner_lifecycle_recoveries.any?(&:reactivation_available?)
    @open_export_request_account_ids = open_export_request_account_ids

    if owner_lifecycle_restricted?
      @self_managed_plans_available = self_managed_plans_available?
      visible_recoveries = @owner_lifecycle_recoveries.select(&:visible?)
      @owner_onboarding_only = visible_recoveries.any? && visible_recoveries.all?(&:onboarding?)
      render :restricted_owner
      return
    end

    @billing_portal_available = billing_portal_available? && @owner_lifecycle_recoveries.none?(&:visible?)
    @dashboard_account = scoped_accounts.limit(2).to_a.then { |accounts| accounts.one? ? accounts.first : nil }
    @vessels = scoped_vessels.active.includes(:account, :reminders, :service_visits).with_attached_primary_photo.ordered
    @upcoming_reminders = scoped_reminders.includes(asset: :account).upcoming.limit(6)
    @recent_service_visits = scoped_service_visits.includes(:asset, :performed_by_user).recent.limit(5)
    @follow_up_items = scoped_service_visits.includes(:asset).with_open_follow_up.recent.limit(5)
    @recent_documents = scoped_documents.includes(:asset, :account).order(created_at: :desc).limit(5)
    @active_vessels_count = scoped_vessels.active.count
    @open_notes_count = scoped_binder_notes.where.not(note_type: "owner_preference").count
    @upcoming_service_items_count = scoped_reminders.upcoming.count
    @documents_count = scoped_documents.count
  end

  private

  def self_managed_plans_available?
    account = Billing::StripeCheckoutAccountResolver.call(current_user)
    subscription = account.subscription
    subscription&.provider == Subscription::LOCAL_PROVIDER &&
      subscription.external_customer_id.blank? &&
      subscription.external_subscription_id.blank?
  rescue Billing::StripeCheckoutAccountResolver::ResolutionError
    false
  end

  def reactivation_options
    Billing::SubscriptionPlanCatalog.new.enabled_options
  rescue Billing::SubscriptionPlanCatalog::ConfigurationError
    []
  end

  def open_export_request_account_ids
    account_ids = @owner_lifecycle_recoveries.filter_map do |recovery|
      recovery.account.id if recovery.export_available?
    end
    return [] if account_ids.empty?

    AccountExportRequest.open.where(account_id: account_ids).pluck(:account_id)
  end

  def billing_portal_available?
    account = Billing::StripeCheckoutAccountResolver.call(current_user)
    Billing::StripePortalSessionCreator.eligible_account?(account)
  rescue Billing::StripeCheckoutAccountResolver::ResolutionError
    false
  end
end
