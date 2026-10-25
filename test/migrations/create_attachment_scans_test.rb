require "test_helper"
require Rails.root.join("db/migrate/20261022150000_create_attachment_scans")

class CreateAttachmentScansTest < ActiveSupport::TestCase
  test "rollback is explicitly irreversible and preserves scan state" do
    error = assert_raises(ActiveRecord::IrreversibleMigration) do
      CreateAttachmentScans.new.down
    end

    assert_includes error.message, "security-sensitive"
    assert ActiveRecord::Base.connection.table_exists?(:attachment_scans)
  end

  test "backfill trusts each attached blob once and ignores stale unattached blobs" do
    account = create_account(name: "Scan Backfill Account")
    first_document = Document.create!(account:, title: "First", document_type: "other")
    second_document = Document.create!(account:, title: "Second", document_type: "other")
    attached_blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("attached"),
      filename: "attached.pdf",
      content_type: "application/pdf"
    )
    unattached_blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("stale"),
      filename: "stale.pdf",
      content_type: "application/pdf"
    )
    first_document.file.attach(attached_blob)
    second_document.file.attach(attached_blob)

    CreateAttachmentScans.new.suppress_messages do
      CreateAttachmentScans.new.backfill_trusted_existing_attachments
      CreateAttachmentScans.new.backfill_trusted_existing_attachments
    end

    scan = AttachmentScan.find_by!(active_storage_blob: attached_blob)
    assert_equal "trusted_existing", scan.status
    assert_equal "ROLLOUT_BACKFILL", scan.status_code
    assert_equal 1, AttachmentScan.where(active_storage_blob: attached_blob).count
    assert_not AttachmentScan.exists?(active_storage_blob: unattached_blob)
  end
end
