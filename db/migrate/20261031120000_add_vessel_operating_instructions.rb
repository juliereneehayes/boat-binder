class AddVesselOperatingInstructions < ActiveRecord::Migration[8.1]
  COLUMNS = %i[
    engine_startup_instructions
    engine_shutdown_instructions
    battery_shore_power_instructions
    operating_notes
  ].freeze

  def up
    COLUMNS.each { |column| add_column :assets, column, :text }
  end

  def down
    if table_exists?(:assets) && operating_instructions_exist?
      raise ActiveRecord::IrreversibleMigration,
        "vessel operating instructions exist; leave the additive columns in place"
    end

    COLUMNS.reverse_each do |column|
      remove_column :assets, column, :text if column_exists?(:assets, column)
    end
  end

  private

  def operating_instructions_exist?
    predicate = COLUMNS
      .select { |column| column_exists?(:assets, column) }
      .map { |column| "#{quote_column_name(column)} IS NOT NULL" }
      .join(" OR ")
    return false if predicate.blank?

    select_value("SELECT EXISTS (SELECT 1 FROM assets WHERE #{predicate} LIMIT 1)")
  end
end
