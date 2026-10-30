class ManagedServiceRelationship
  class Transition
    AccessDenied = Class.new(StandardError)

    def self.call!(account:, active:, actor:, request_id: nil)
      authorize!(account:, active:, actor:)

      account.with_lock do
        relationship = ManagedServiceRelationship.find_by(account:)
        return if relationship.nil? && !active

        relationship ||= ManagedServiceRelationship.new(account:)
        return relationship if relationship.persisted? && relationship.active? == active

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
