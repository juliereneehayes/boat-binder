module Authorization
  extend ActiveSupport::Concern

  ACCESS_DENIED_MESSAGE = "That page is not available for your account."
  OWNER_READABLE_LIFECYCLE_PHASES = %i[
    current_entitlement
    read_only_grace
    payment_recovery_pending
  ].freeze

  included do
    helper_method :current_user, :admin_user?, :internal_user?, :owner_user?, :can_manage_records?,
      :can_manage_account?, :can_create_vessels?, :owner_lifecycle_restricted?, :owner_lifecycle_recoveries
  end

  private

  def current_user
    Current.user
  end

  def admin_user?
    current_user&.admin?
  end

  def internal_user?
    current_user&.internal?
  end

  def owner_user?
    current_user&.owner?
  end

  def can_manage_records?(account = nil)
    return can_manage_account?(account) if account.present?

    internal_user? || manageable_account_ids.any?
  end

  def can_manage_account?(account)
    return true if internal_user?
    return false unless account.present?

    manageable_account_ids.include?(account.id)
  end

  def can_create_vessels?
    internal_user? || manageable_account_ids.one?
  end

  def require_admin!
    deny_access! unless admin_user?
  end

  def require_internal!
    deny_access! unless internal_user?
  end

  def require_write_access!(account = nil)
    deny_access! unless can_manage_records?(account)
  end

  def require_owner_read_access!
    deny_access! if owner_lifecycle_restricted?
  end

  def deny_access!
    if request.format.html? || request.format.turbo_stream?
      redirect_to root_path, alert: ACCESS_DENIED_MESSAGE
    else
      head :forbidden
    end
  end

  def ensure_active_user!
    return unless authenticated?
    return if current_user&.active?

    terminate_session
    redirect_to new_session_path, alert: Authentication::GENERIC_LOGIN_FAILURE_MESSAGE
  end

  def scoped_accounts
    return Account.all if internal_user?

    Account.where(id: readable_account_ids)
  end

  def manageable_accounts
    return Account.all if internal_user?

    Account.where(id: manageable_account_ids)
  end

  def manageable_account_ids
    @manageable_account_ids ||= if current_user&.owner? && current_user.active?
      eligible_memberships = current_user.account_memberships.active.where(access_level: "editor")
      evaluated_at = Time.current

      Account.active
        .joins(:account_memberships)
        .merge(eligible_memberships)
        .includes(:subscription)
        .filter_map do |account|
          next unless Billing::OwnerUserLimit.compliant?(account)

          entitlement = Billing::SelfManagedEntitlement.new(account:, now: evaluated_at)
          account.id if entitlement.qualifying?
        end
    else
      []
    end
  end

  def scoped_assets
    return Asset.all if internal_user?

    Asset.where(account_id: readable_account_ids)
  end

  def scoped_vessels
    scoped_assets.vessels
  end

  def manageable_vessels
    return Asset.vessels if internal_user?

    Asset.vessels.where(account_id: manageable_account_ids)
  end

  def scoped_documents
    return Document.all if internal_user?

    Document.where(account_id: readable_account_ids)
  end

  def scoped_reminders
    return Reminder.all if internal_user?

    Reminder.joins(:asset).where(assets: { account_id: readable_account_ids })
  end

  def scoped_service_visits
    return ServiceVisit.all if internal_user?

    ServiceVisit.joins(:asset).where(assets: { account_id: readable_account_ids })
  end

  def scoped_binder_notes
    return BinderNote.all if internal_user?

    BinderNote.where(account_id: readable_account_ids)
  end

  def readable_account_ids
    @readable_account_ids ||= if current_user&.owner? && current_user.active?
      evaluated_at = Time.current

      owner_read_candidate_accounts.filter_map do |account|
        next unless Billing::OwnerUserLimit.compliant?(account)

        phase = Billing::SelfManagedEntitlement.new(account:, now: evaluated_at).lifecycle_phase
        account.id if OWNER_READABLE_LIFECYCLE_PHASES.include?(phase)
      end
    else
      []
    end
  end

  def owner_lifecycle_restricted?
    owner_user? && current_user.active? && owner_read_candidate_accounts.any? && readable_account_ids.empty?
  end

  def owner_lifecycle_recoveries
    @owner_lifecycle_recoveries ||= if current_user&.owner? && current_user.active?
      evaluated_at = Time.current

      current_user.account_memberships.active.includes(account: :subscription).filter_map do |membership|
        account = membership.account
        next unless account.active? && account.account_type == "client"

        Billing::OwnerLifecycleRecovery.new(account:, membership:, now: evaluated_at)
      end
    else
      []
    end
  end

  def owner_read_candidate_accounts
    @owner_read_candidate_accounts ||= Account.active
      .joins(:account_memberships)
      .merge(current_user.account_memberships.active)
      .includes(:subscription)
  end
end
