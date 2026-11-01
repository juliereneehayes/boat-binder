module Authorization
  class SelfManagedOwnerPolicy
    def initialize(user:, now: Time.current)
      @user = user
      @now = now
    end

    def readable_account_ids
      @readable_account_ids ||= eligible_account_ids(write: false)
    end

    def writable_account_ids
      @writable_account_ids ||= eligible_account_ids(write: true)
    end

    def candidate_accounts
      return Account.none unless eligible_user?

      @candidate_accounts ||= Account.active
        .joins(:account_memberships)
        .merge(user.account_memberships.active)
        .includes(:subscription)
    end

    private

    attr_reader :now, :user

    def eligible_account_ids(write:)
      return [] unless eligible_user?

      memberships = user.account_memberships.active
      memberships = memberships.where(access_level: "editor") if write

      Account.active
        .joins(:account_memberships)
        .merge(memberships)
        .includes(:subscription)
        .filter_map do |account|
          next unless Billing::OwnerUserLimit.compliant?(account)

          entitlement = Billing::SelfManagedEntitlement.new(account:, now:)
          account.id if write ? entitlement.qualifying? : readable?(entitlement)
        end
    end

    def eligible_user?
      user&.owner? && user.active?
    end

    def readable?(entitlement)
      Authorization::OWNER_READABLE_LIFECYCLE_PHASES.include?(entitlement.lifecycle_phase)
    end
  end
end
