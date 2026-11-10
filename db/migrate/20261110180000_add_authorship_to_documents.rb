class AddAuthorshipToDocuments < ActiveRecord::Migration[8.1]
  def change
    add_reference :documents, :created_by_user, foreign_key: { to_table: :users }
    add_column :documents, :author_kind, :string
    add_check_constraint :documents, "author_kind IN ('owner', 'professional')", name: "chk_documents_author_kind"
  end
end
