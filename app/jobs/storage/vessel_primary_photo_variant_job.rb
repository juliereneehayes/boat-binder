module Storage
  class VesselPrimaryPhotoVariantJob < ApplicationJob
    queue_as :background

    limits_concurrency key: ->(attachment_id, _blob_id) { attachment_id },
      duration: 10.minutes,
      on_conflict: :discard

    VariantProcessingError = Class.new(StandardError)

    def self.enqueue_for(attachment)
      return unless attachment&.record_type == "Asset" && attachment.name == "primary_photo"

      perform_later(attachment.id, attachment.blob_id)
    end

    def perform(attachment_id, blob_id)
      attachment = ActiveStorage::Attachment.find_by(
        id: attachment_id,
        blob_id: blob_id,
        record_type: "Asset",
        name: "primary_photo"
      )
      return unless attachment&.record&.asset_type == "vessel"
      return unless AttachmentScan.available_blob?(attachment.blob)

      variant = attachment.variant(:card)
      return if variant.image&.attached?
      return unless ActiveStorage::Attachment.exists?(id: attachment_id, blob_id: blob_id)

      variant.processed
    rescue StandardError => error
      Rails.logger.error(
        "Vessel primary photo variant processing failed " \
          "attachment_id=#{attachment_id} blob_id=#{blob_id} exception_class=#{error.class.name}"
      )
      raise VariantProcessingError, "vessel primary photo variant processing failed", cause: nil
    end
  end
end
