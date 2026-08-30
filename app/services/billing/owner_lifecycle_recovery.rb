module Billing
  class OwnerLifecycleRecovery
    REACTIVATION_PHASES = %i[read_only_grace retained_inactive archive_eligible].freeze
    EXPORT_PHASE_CONTEXTS = {
      payment_recovery_pending: "payment_recovery_pending",
      read_only_grace: "read_only_grace",
      retained_inactive: "retained_inactive",
      archive_eligible: "archive_eligible"
    }.freeze

    attr_reader :account, :membership, :phase, :entitlement_ended_at, :entitlement_ends_at

    def initialize(account:, membership:, now: Time.current)
      @account = account
      @membership = membership
      @now = now
      entitlement = SelfManagedEntitlement.new(account:, now:)
      @phase = entitlement.lifecycle_phase
      @entitlement_ended_at = entitlement.entitlement_ended_at
      @entitlement_ends_at = entitlement.entitlement_ends_at
    end

    def visible?
      phase != :current_entitlement || scheduled_cancellation?
    end

    def scheduled_cancellation?
      phase == :current_entitlement && account.subscription&.scheduled_cancellation?(now:)
    end

    def status_label
      return "Cancellation scheduled" if scheduled_cancellation?

      {
        payment_recovery_pending: "Billing needs attention",
        read_only_grace: "Read-only access",
        retained_inactive: "Account retained",
        archive_eligible: "Restoration review",
        manual_review: "Account review needed",
        unavailable: "Account review needed"
      }.fetch(phase, "Account status")
    end

    def title
      return "Your plan is scheduled to end" if scheduled_cancellation?

      {
        payment_recovery_pending: "Please update your billing details",
        read_only_grace: "Your binder is read-only",
        retained_inactive: "Your binder is currently unavailable",
        archive_eligible: "Your binder may need support to restore",
        manual_review: "Your account needs review",
        unavailable: "Your account needs review"
      }.fetch(phase, "Your Boat Binder account")
    end

    def description
      return "Your normal access remains available through the paid-through date below." if scheduled_cancellation?

      {
        payment_recovery_pending: "There is a billing problem to resolve. Your existing authorized records remain viewable while billing is being addressed.",
        read_only_grace: "Your Self Managed access ended. Existing authorized records remain viewable during the 90-day read-only period, but changes are unavailable.",
        retained_inactive: "Your account and data are being retained for potential reactivation. Normal binder access is unavailable.",
        archive_eligible: "Normal binder access is unavailable and restoration may require support. This does not mean your data has been archived or deleted.",
        manual_review: "Online billing recovery is not available for this account. Contact an administrator for help.",
        unavailable: "Online billing recovery is not available for this account. Contact an administrator for help."
      }.fetch(phase, "Your account remains secure.")
    end

    def date_label
      return "Paid through" if scheduled_cancellation?

      "Access ended" if phase == :read_only_grace
    end

    def date
      return account.subscription.scheduled_cancellation_at if scheduled_cancellation?

      entitlement_ended_at if phase == :read_only_grace
    end

    def billing_portal_available?
      editor? && StripePortalSessionCreator.eligible_account?(account)
    end

    def reactivation_available?
      editor? && REACTIVATION_PHASES.include?(phase) && account.subscription&.canceled?
    end

    def export_context
      return "scheduled_cancellation" if scheduled_cancellation?

      EXPORT_PHASE_CONTEXTS[phase]
    end

    def export_available?
      export_context.present?
    end

    def account_reference
      @account_reference ||= OwnerAccountReference.generate(account)
    end

    private

    attr_reader :now

    def editor?
      membership.access_level == "editor"
    end
  end
end
