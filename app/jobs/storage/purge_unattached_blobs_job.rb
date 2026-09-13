module Storage
  class PurgeUnattachedBlobsJob < ApplicationJob
    queue_as :background

    MINIMUM_BLOB_AGE = 24.hours

    def perform(older_than: MINIMUM_BLOB_AGE, now: Time.current)
      cutoff = now - older_than

      ActiveStorage::Blob.unattached.where(created_at: ...cutoff).find_each do |blob|
        purge_if_still_unattached(blob)
      rescue StandardError => error
        Rails.logger.error(
          "Unattached blob cleanup failed for blob_id=#{blob.id}: #{error.class}"
        )
        raise
      end
    end

    private

    def purge_if_still_unattached(blob)
      blob.with_lock do
        return if blob.attachments.exists?

        blob.purge
      end
    end
  end
end
