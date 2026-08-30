class AddCancelAtToSubscriptions < ActiveRecord::Migration[8.1]
  def up
    add_column :subscriptions, :cancel_at, :datetime
  end

  def down
    if select_value(<<~SQL.squish)
      SELECT 1
      FROM subscriptions
      WHERE cancel_at IS NOT NULL
      LIMIT 1
    SQL
      raise ActiveRecord::IrreversibleMigration,
        "Cannot remove subscriptions.cancel_at while canonical cancellation boundaries exist"
    end

    remove_column :subscriptions, :cancel_at
  end
end
