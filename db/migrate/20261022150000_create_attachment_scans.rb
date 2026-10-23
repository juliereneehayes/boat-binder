class CreateAttachmentScans < ActiveRecord::Migration[8.1]
  def up
    create_table :attachment_scans do |t|
      t.references :active_storage_blob,
        null: false,
        foreign_key: { to_table: :active_storage_blobs, on_delete: :cascade },
        index: { unique: true }
      t.string :status, null: false, default: "pending"
      t.string :provider, null: false, default: "guardduty"
      t.integer :check_count, null: false, default: 0
      t.datetime :last_checked_at
      t.datetime :completed_at
      t.string :status_code
      t.timestamps
    end

    add_check_constraint :attachment_scans,
      "status IN ('pending', 'clean', 'rejected', 'failed', 'trusted_existing')",
      name: "attachment_scans_status"
    add_check_constraint :attachment_scans,
      "provider = 'guardduty'",
      name: "attachment_scans_provider"
    add_check_constraint :attachment_scans,
      "check_count >= 0",
      name: "attachment_scans_nonnegative_check_count"

    backfill_trusted_existing_attachments
  end

  def down
    drop_table :attachment_scans
  end

  def backfill_trusted_existing_attachments
    execute <<~SQL.squish
      INSERT INTO attachment_scans
        (active_storage_blob_id, status, provider, check_count, completed_at, status_code, created_at, updated_at)
      SELECT DISTINCT blob_id, 'trusted_existing', 'guardduty', 0,
        CURRENT_TIMESTAMP::timestamp, 'ROLLOUT_BACKFILL',
        CURRENT_TIMESTAMP::timestamp, CURRENT_TIMESTAMP::timestamp
      FROM active_storage_attachments
      ON CONFLICT (active_storage_blob_id) DO NOTHING
    SQL
  end
end
