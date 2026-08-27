class AddLifecycleTimingToSubscriptions < ActiveRecord::Migration[8.1]
  def change
    add_column :subscriptions, :entitlement_ended_at, :datetime
    add_column :subscriptions, :past_due_observed_at, :datetime
  end
end
