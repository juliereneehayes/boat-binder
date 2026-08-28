class DashboardController < ApplicationController
  def index
    if owner_lifecycle_restricted?
      @self_managed_plans_available = self_managed_plans_available?
      render :restricted_owner
      return
    end

    @billing_portal_available = billing_portal_available?
    @dashboard_account = scoped_accounts.limit(2).to_a.then { |accounts| accounts.one? ? accounts.first : nil }
    @vessels = scoped_vessels.active.includes(:account, :reminders, :service_visits).with_attached_primary_photo.ordered
    @upcoming_reminders = scoped_reminders.includes(asset: :account).upcoming.limit(6)
    @recent_service_visits = scoped_service_visits.includes(:asset, :performed_by_user).recent.limit(5)
    @follow_up_items = scoped_service_visits.includes(:asset).where(follow_up_needed: true).recent.limit(5)
    @recent_documents = scoped_documents.includes(:asset, :account).order(created_at: :desc).limit(5)
    @active_vessels_count = scoped_vessels.active.count
    @open_notes_count = scoped_binder_notes.where.not(note_type: "owner_preference").count
    @upcoming_service_items_count = scoped_reminders.upcoming.count
    @documents_count = scoped_documents.count
  end

  private

  def self_managed_plans_available?
    Billing::StripeCheckoutAccountResolver.call(current_user).present?
  rescue Billing::StripeCheckoutAccountResolver::ResolutionError
    false
  end

  def billing_portal_available?
    account = Billing::StripeCheckoutAccountResolver.call(current_user)
    Billing::StripePortalSessionCreator.eligible_account?(account)
  rescue Billing::StripeCheckoutAccountResolver::ResolutionError
    false
  end
end
