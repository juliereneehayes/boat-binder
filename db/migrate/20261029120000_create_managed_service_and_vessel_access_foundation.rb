class CreateManagedServiceAndVesselAccessFoundation < ActiveRecord::Migration[8.1]
  def up
    create_table :managed_service_relationships do |t|
      t.references :account, null: false, foreign_key: true, index: { unique: true }
      t.boolean :active, null: false, default: false

      t.timestamps
    end

    create_table :vessel_access_information do |t|
      t.references :asset, null: false, foreign_key: true, index: { unique: true }
      t.text :restricted_details, null: false

      t.timestamps
    end
  end

  def down
    if table_contains_rows?(:vessel_access_information) || table_contains_rows?(:managed_service_relationships)
      raise ActiveRecord::IrreversibleMigration,
        "managed service or encrypted vessel access records exist; leave the additive tables in place"
    end

    drop_table :vessel_access_information, if_exists: true
    drop_table :managed_service_relationships, if_exists: true
  end

  private

  def table_contains_rows?(table_name)
    table_exists?(table_name) && select_value("SELECT EXISTS (SELECT 1 FROM #{quote_table_name(table_name)} LIMIT 1)")
  end
end
