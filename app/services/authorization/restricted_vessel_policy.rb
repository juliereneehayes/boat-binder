module Authorization
  class RestrictedVesselPolicy
    AccessDenied = Class.new(StandardError)

    def initialize(user:, now: Time.current)
      @user = user
      @now = now
    end

    def readable_vessels
      Asset.vessels.where(account_id: readable_account_ids)
    end

    def writable_vessels
      Asset.vessels.where(account_id: writable_account_ids)
    end

    def authorize_write!(vessel)
      raise AccessDenied, Authorization::ACCESS_DENIED_MESSAGE unless vessel&.persisted?

      writable_vessels.find(vessel.id)
    rescue ActiveRecord::RecordNotFound
      raise AccessDenied, Authorization::ACCESS_DENIED_MESSAGE
    end

    private

    attr_reader :now, :user

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
