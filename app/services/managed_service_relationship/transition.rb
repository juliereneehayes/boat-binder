class ManagedServiceRelationship
  class Transition
    AccessDenied = Class.new(StandardError)
    EnrollmentError = Class.new(StandardError)

    def self.call!(account:, active:, actor:, request_id: nil)
      authorize!(account:, active:, actor:)

      account.with_lock do
        relationship = ManagedServiceRelationship.find_by(account:)
        return if relationship.nil? && !active

        relationship ||= ManagedServiceRelationship.new(account:)
        return relationship if relationship.persisted? && relationship.active? == active

        if active
          unless account.account_type == "client"
            raise EnrollmentError, "HYC Managed Service is available for Owner Accounts."
          end
          unless Billing::OwnerUserLimit.compliant_for_plan?(account, plan_key: Billing::SubscriptionPlanCatalog::SELF_MANAGED_PLAN_KEY)
            raise EnrollmentError, "HYC Managed Service allows one active Owner user. Review linked Owner access before activating."
          end
          subscription = account.subscription
          if subscription&.provider == Subscription::STRIPE_PROVIDER && subscription.plan == "self_managed" &&
              !subscription.canceled? && !subscription.expired?
            raise EnrollmentError, "Review the existing Self Managed subscription before activating HYC Managed Service. Billing has not been changed."
          end
          if account.billing_checkout_attempts.active.exists?
            raise EnrollmentError, "Resolve the existing Self Managed checkout before activating HYC Managed Service."
          end
        end

        relationship.active = active
        relationship.save!
        SecurityAudit::Recorder.record!(
          action: active ? "managed_service_relationship.activated" : "managed_service_relationship.revoked",
          actor:,
          account:,
          target: relationship,
          request_id:,
          changed_fields: %w[active]
        )
        relationship
      end
    end

    def self.authorize!(account:, active:, actor:)
      valid_request = account&.persisted? && [ true, false ].include?(active) &&
        actor&.persisted? && actor.active? && actor.admin?
      return if valid_request

      raise AccessDenied, Authorization::ACCESS_DENIED_MESSAGE
    end
    private_class_method :authorize!

    private_class_method :new
  end
end
