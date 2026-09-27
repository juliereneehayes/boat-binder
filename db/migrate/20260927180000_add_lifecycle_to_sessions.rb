class AddLifecycleToSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :sessions, :last_seen_at, :datetime
    add_column :sessions, :expires_at, :datetime
  end
end
