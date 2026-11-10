class AddAuthorKindToServiceVisits < ActiveRecord::Migration[8.1]
  def change
    # Historical creator roles cannot be verified from the current User role.
    # Keep existing rows NULL so Owner writes fail closed.
    add_column :service_visits, :author_kind, :string
    add_check_constraint :service_visits,
      "author_kind IN ('owner', 'professional')",
      name: "chk_service_visits_author_kind"
  end
end
