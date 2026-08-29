module Billing
  class StripeSubscriptionHandoff
    def self.allowed?(subscription:, attempt:, incoming_subscription_id:)
      current_id = subscription.external_subscription_id.to_s
      incoming_id = incoming_subscription_id.to_s

      if attempt.reactivation?
        replaced_id = attempt.replaces_external_subscription_id.to_s
        incoming_id.present? && incoming_id != replaced_id &&
          [ replaced_id, incoming_id ].include?(current_id)
      else
        current_id.blank? || current_id == incoming_id
      end
    end
  end
end
