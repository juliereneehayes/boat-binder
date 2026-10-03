class CreateSecurityAuditEvents < ActiveRecord::Migration[8.1]
  def up
    create_table :security_audit_events do |t|
      # Historical identifiers intentionally have no foreign keys. Audit
      # attribution survives future deletion of the referenced live rows.
      t.bigint :actor_user_id
      t.bigint :account_id
      t.string :action, null: false
      t.string :target_type
      t.bigint :target_id
      t.string :request_id
      t.string :outcome, null: false
      t.inet :source_ip
      t.string :changed_fields, array: true, default: [], null: false
      t.datetime :created_at, default: -> { "CURRENT_TIMESTAMP" }, null: false
    end

    add_index :security_audit_events, %i[action created_at]
    add_index :security_audit_events, %i[actor_user_id created_at]
    add_index :security_audit_events, %i[account_id created_at]
    add_index :security_audit_events, %i[target_type target_id created_at],
      name: "idx_security_audit_events_target_created_at"
    add_index :security_audit_events, :request_id
    add_check_constraint :security_audit_events,
      "outcome IN ('succeeded', 'failed', 'denied')",
      name: "chk_security_audit_events_outcome"
    add_check_constraint :security_audit_events,
      "(target_type IS NULL) = (target_id IS NULL)",
      name: "chk_security_audit_events_target_pair"
  end

  def down
    if table_exists?(:security_audit_events) &&
        select_value("SELECT EXISTS (SELECT 1 FROM security_audit_events LIMIT 1)")
      raise ActiveRecord::IrreversibleMigration,
        "security_audit_events contains append-only history; leave the additive table in place"
    end

    drop_table :security_audit_events, if_exists: true
  end
end
