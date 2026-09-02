module Billing
  class OwnerUserLimit
    ERROR_MESSAGE = "Self Managed accounts allow one active Owner user."

    Violation = Data.define(:account_id, :active_owner_count, :limit)

    class << self
      def compliant?(account)
        compliant_for_plan?(account, plan_key: account&.subscription&.plan)
      end

      def compliant_for_plan?(account, plan_key:)
        limit = limit_for(plan_key)
        return true unless account&.persisted? && limit

        active_owner_count(account) <= limit
      end

      def allows_owner?(account:, user_id:, plan_key: account&.subscription&.plan)
        limit = limit_for(plan_key)
        return true unless account&.persisted? && limit

        active_owner_count(account, excluding_user_id: user_id) + 1 <= limit
      end

      def active_owner_count(account, excluding_user_id: nil)
        memberships = account.account_memberships.active
          .joins(:user)
          .where(users: { role: "owner" })
        memberships = memberships.where.not(user_id: excluding_user_id) if excluding_user_id
        memberships.distinct.count(:user_id)
      end

      def violations
        limit = limit_for(SubscriptionPlanCatalog::SELF_MANAGED_PLAN_KEY)

        Account.joins(:subscription)
          .where(subscriptions: { plan: SubscriptionPlanCatalog::SELF_MANAGED_PLAN_KEY })
          .order(:id)
          .filter_map do |account|
            count = active_owner_count(account)
            Violation.new(account_id: account.id, active_owner_count: count, limit:) if count > limit
          end
      end

      private

      def limit_for(plan_key)
        SubscriptionPlanCatalog.entitlements_for_plan(plan_key).fetch(:owner_user_limit, nil)
      end
    end
  end
end
