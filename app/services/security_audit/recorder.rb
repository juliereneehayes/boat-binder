module SecurityAudit
  class Recorder
    class << self
      def record!(action:, outcome: "succeeded", actor: nil, account: nil, target: nil,
        request_id: nil, source_ip: nil, changed_fields: [])
        validate_account_context!(account:, target:)

        SecurityAuditEvent.create!(
          action:,
          outcome:,
          actor_user: actor,
          account:,
          target_type: target&.model_name&.name,
          target_id: target&.id,
          request_id: request_id.presence,
          source_ip:,
          changed_fields: normalize_changed_fields(changed_fields)
        )
      end

      private

      def validate_account_context!(account:, target:)
        return if account.nil? || target.nil?

        matches = case target
        when Account
          target.id == account.id
        when User
          target.account_memberships.exists?(account_id: account.id)
        else
          target.respond_to?(:account_id) && target.account_id == account.id
        end
        return if matches

        raise ArgumentError, "account does not match the audit target"
      end

      def normalize_changed_fields(changed_fields)
        Array(changed_fields).map do |field|
          unless field.is_a?(String) || field.is_a?(Symbol)
            raise ArgumentError, "changed_fields must contain field names"
          end

          field.to_s
        end.uniq.sort
      end
    end
  end
end
