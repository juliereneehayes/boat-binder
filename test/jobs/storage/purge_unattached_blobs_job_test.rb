require "test_helper"

module Storage
  class PurgeUnattachedBlobsJobTest < ActiveJob::TestCase
    test "purges old unattached blobs while retaining recent and attached blobs" do
      now = Time.zone.local(2026, 9, 13, 12)
      old_blob = create_blob("old.pdf", created_at: now - PurgeUnattachedBlobsJob::MINIMUM_BLOB_AGE - 1.minute)
      recent_blob = create_blob("recent.pdf", created_at: now - PurgeUnattachedBlobsJob::MINIMUM_BLOB_AGE + 1.minute)
      attached_blob = create_blob("attached.pdf", created_at: now - 2.days)
      account = create_account(name: "Cleanup Account")
      document = Document.create!(account:, title: "Attached", document_type: "other")
      document.file.attach(attached_blob)

      PurgeUnattachedBlobsJob.perform_now(now:)

      assert_not ActiveStorage::Blob.exists?(old_blob.id)
      assert ActiveStorage::Blob.exists?(recent_blob.id)
      assert ActiveStorage::Blob.exists?(attached_blob.id)
      assert_equal attached_blob.id, document.reload.file.blob.id
    end

    test "rechecks attachment ownership before purging each candidate" do
      blob = create_blob("raced.pdf", created_at: 2.days.ago)
      account = create_account(name: "Cleanup Recheck Account")
      document = Document.create!(account:, title: "Attached during scan", document_type: "other")

      with_replaced_method(ActiveStorage::Blob, :unattached, -> { ActiveStorage::Blob.where(id: blob.id) }) do
        document.file.attach(blob)
        PurgeUnattachedBlobsJob.perform_now
      end

      assert ActiveStorage::Blob.exists?(blob.id)
      assert_equal blob.id, document.reload.file.blob.id
    end

    test "logs and reraises purge failures for Solid Queue observability" do
      blob = create_blob("failure.pdf", created_at: 2.days.ago)
      error = IOError.new("storage unavailable")

      job = PurgeUnattachedBlobsJob.new
      with_replaced_method(job, :purge_if_still_unattached, ->(_blob) { raise error }) do
        with_replaced_method(ActiveStorage::Blob, :unattached, -> { ActiveStorage::Blob.where(id: blob.id) }) do
          assert_raises(IOError) { job.perform }
        end
      end
    end

    private

    def create_blob(filename, created_at:)
      ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new(filename),
        filename:,
        content_type: "application/pdf"
      ).tap { |blob| blob.update_column(:created_at, created_at) }
    end

    def with_replaced_method(receiver, method_name, replacement)
      original = receiver.method(method_name)
      receiver.define_singleton_method(method_name, replacement)
      yield
    ensure
      receiver.define_singleton_method(method_name, original)
    end
  end
end
