class AddFollowUpCompletionAudit < ActiveRecord::Migration[8.1]
  def change
    add_reference :service_visits, :follow_up_completed_by_user, foreign_key: { to_table: :users }
    add_column :service_visits, :follow_up_completed_at, :datetime
    add_index :service_visits, %i[follow_up_needed follow_up_completed_at],
      name: "index_service_visits_on_open_follow_up"
    add_check_constraint :service_visits,
      "(follow_up_completed_at IS NULL) = (follow_up_completed_by_user_id IS NULL)",
      name: "chk_service_visits_follow_up_completion_pair"
    add_check_constraint :service_visits,
      "follow_up_completed_at IS NULL OR follow_up_needed",
      name: "chk_service_visits_follow_up_completion_needed"

    create_table :service_visit_follow_up_events do |t|
      t.references :service_visit, null: false, foreign_key: true
      t.references :actor_user, null: false, foreign_key: { to_table: :users }
      t.string :action, null: false

      t.timestamps
    end

    add_index :service_visit_follow_up_events, %i[service_visit_id created_at],
      name: "index_follow_up_events_on_visit_and_created_at"
    add_check_constraint :service_visit_follow_up_events,
      "action IN ('completed', 'reopened')",
      name: "chk_service_visit_follow_up_events_action"
  end
end
