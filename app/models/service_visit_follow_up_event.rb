class ServiceVisitFollowUpEvent < ApplicationRecord
  ACTIONS = %w[completed reopened].freeze

  belongs_to :service_visit
  belongs_to :actor_user, class_name: "User"

  validates :action, inclusion: { in: ACTIONS }
end
