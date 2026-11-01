module Authorization
  class RestrictedVesselPolicy
    AccessDenied = Class.new(StandardError)

    def initialize(user:, now: Time.current, self_managed_owner_policy: nil)
      @user = user
      @now = now
      @self_managed_owner_policy = self_managed_owner_policy
    end

    def readable_vessels
      Asset.vessels.where(account_id: readable_account_ids)
    end

    def writable_vessels
      Asset.vessels.where(account_id: writable_account_ids)
    end

    def authorize_write!(vessel)
      return vessel if writable?(vessel)

      raise AccessDenied, Authorization::ACCESS_DENIED_MESSAGE
    end

    def authorize_read!(vessel)
      return vessel if readable?(vessel)

      raise AccessDenied, Authorization::ACCESS_DENIED_MESSAGE
    end

    def readable?(vessel)
      authorized_for_account?(vessel&.account, write: false) if vessel&.persisted?
    end

    def writable?(vessel)
      authorized_for_account?(vessel&.account, write: true) if vessel&.persisted?
    end

    private

    attr_reader :now, :user

    def authorized_for_account?(account, write:)
      return false unless user&.active? && account&.persisted?

      if ManagedServiceRelationship.effective_for?(account)
        return true if user.internal?
        return false unless user.owner?

        memberships = user.account_memberships.active.where(account_id: account.id)
        memberships = memberships.where(access_level: "editor") if write
        return memberships.exists?
      end

      return false unless user.owner?

      account_ids = write ? self_managed_owner_policy.writable_account_ids : self_managed_owner_policy.readable_account_ids
      account.id.in?(account_ids)
    end

    def readable_account_ids
      return [] unless user&.active?
      return managed_service_account_ids if user.internal?
      return [] unless user.owner?

      (self_managed_owner_policy.readable_account_ids + managed_service_owner_account_ids).uniq
    end

    def writable_account_ids
      return [] unless user&.active?
      return managed_service_account_ids if user.internal?
      return [] unless user.owner?

      (self_managed_owner_policy.writable_account_ids + managed_service_owner_account_ids(write: true)).uniq
    end

    def managed_service_account_ids
      ManagedServiceRelationship.effective.select(:account_id)
    end

    def managed_service_owner_account_ids(write: false)
      memberships = user.account_memberships.active
      memberships = memberships.where(access_level: "editor") if write

      ManagedServiceRelationship.effective
        .where(account_id: memberships.select(:account_id))
        .pluck(:account_id)
    end

    def self_managed_owner_policy
      @self_managed_owner_policy ||= Authorization::SelfManagedOwnerPolicy.new(user:, now:)
    end
  end
end
