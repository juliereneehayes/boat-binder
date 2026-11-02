module Storage
  class VesselPrimaryPhotoVariantJob < ApplicationJob
    queue_as :background

    PROCESSING_STATE_METADATA_KEY = "boat_binder_vessel_primary_photo_card_variant"
    PROCESSING_STATE_VERSION = 1
    PENDING_STATE = "pending"
    PERMANENT_FAILURE_STATE = "permanent_failure"

    PermanentVariantProcessingError = Class.new(StandardError)
    TransientVariantProcessingError = Class.new(StandardError)

    retry_on TransientVariantProcessingError, wait: :polynomially_longer, attempts: 5
    discard_on PermanentVariantProcessingError

    limits_concurrency key: ->(attachment_id, _blob_id) { attachment_id },
      duration: 10.minutes,
      on_conflict: :discard

    class << self
      def enqueue_for(attachment)
        return unless vessel_primary_photo_attachment?(attachment)

        state = status_for(attachment)
        return state unless state == :missing

        blob = attachment.blob
        claim_result = claim_processing(blob)
        return claim_result unless claim_result == :claimed

        enqueued_job = perform_later(attachment.id, blob.id)
        raise ActiveJob::EnqueueError, "card variant could not be enqueued" unless enqueued_job&.successfully_enqueued?

        :pending
      rescue StandardError => error
        begin
          clear_processing_state(blob, expected: PENDING_STATE) if blob && claim_result == :claimed
        rescue StandardError => state_error
          Rails.logger.error(
            "Vessel primary photo variant enqueue cleanup failed " \
              "attachment_id=#{attachment&.id} blob_id=#{attachment&.blob_id} " \
              "exception_class=#{state_error.class.name}"
          )
        end
        Rails.logger.error(
          "Vessel primary photo variant enqueue failed " \
            "attachment_id=#{attachment&.id} blob_id=#{attachment&.blob_id} " \
            "exception_class=#{error.class.name}"
        )
        :missing
      end

      def status_for(attachment)
        return :missing unless vessel_primary_photo_attachment?(attachment)

        image = attachment.variant(:card).image
        return :ready if image&.attached?

        processing_state(attachment.blob)
      end

      def mark_permanent_failure(blob)
        write_processing_state(blob, PERMANENT_FAILURE_STATE)
      end

      def ensure_pending_processing_state(blob)
        result = claim_processing(blob)
        result == :claimed ? :pending : result
      end

      def clear_processing_state(blob, expected: nil)
        changed = false
        blob.with_lock do
          current_state = processing_state(blob)
          if expected.nil? || current_state == expected.to_sym
            blob.update!(metadata: blob.metadata.except(PROCESSING_STATE_METADATA_KEY))
            changed = true
          end
        end
        changed
      end

      private

      def vessel_primary_photo_attachment?(attachment)
        return false unless attachment&.record_type == "Asset" && attachment.name == "primary_photo"

        attachment.record&.asset_type == "vessel"
      end

      def claim_processing(blob)
        result = :missing
        blob.with_lock do
          result = processing_state(blob)
          if result == :missing
            blob.update!(metadata: blob.metadata.merge(
              PROCESSING_STATE_METADATA_KEY => {
                "version" => PROCESSING_STATE_VERSION,
                "state" => PENDING_STATE
              }
            ))
            result = :claimed
          end
        end
        result
      end

      def write_processing_state(blob, state)
        blob.with_lock do
          blob.update!(metadata: blob.metadata.merge(
            PROCESSING_STATE_METADATA_KEY => {
              "version" => PROCESSING_STATE_VERSION,
              "state" => state
            }
          ))
        end
      end

      def processing_state(blob)
        metadata = blob.metadata[PROCESSING_STATE_METADATA_KEY]
        return :missing unless metadata.is_a?(Hash)
        return :missing unless metadata["version"] == PROCESSING_STATE_VERSION

        case metadata["state"]
        when PENDING_STATE
          :pending
        when PERMANENT_FAILURE_STATE
          :permanent_failure
        else
          :missing
        end
      end
    end

    def perform(attachment_id, blob_id)
      attachment = ActiveStorage::Attachment.find_by(
        id: attachment_id,
        blob_id: blob_id,
        record_type: "Asset",
        name: "primary_photo"
      )
      return unless attachment

      blob = attachment.blob
      return if self.class.ensure_pending_processing_state(blob) == :permanent_failure

      unless attachment.record&.asset_type == "vessel"
        self.class.clear_processing_state(blob, expected: PENDING_STATE)
        return
      end
      unless AttachmentScan.available_blob?(blob)
        self.class.clear_processing_state(blob, expected: PENDING_STATE)
        return
      end

      variant = attachment.variant(:card)
      if variant.image&.attached?
        self.class.clear_processing_state(blob, expected: PENDING_STATE)
        return
      end
      unless ActiveStorage::Attachment.exists?(id: attachment_id, blob_id: blob_id)
        self.class.clear_processing_state(blob, expected: PENDING_STATE)
        return
      end

      process_variant(attachment)
      self.class.clear_processing_state(blob, expected: PENDING_STATE)
    rescue StandardError => error
      handle_processing_error(error, attachment_id:, blob_id:, blob:)
    end

    private

    def process_variant(attachment)
      attachment.variant(:card).processed
    end

    def handle_processing_error(error, attachment_id:, blob_id:, blob: nil)
      if permanent_processing_error?(error)
        begin
          self.class.mark_permanent_failure(blob) if blob
        rescue StandardError => state_error
          log_processing_failure(
            state_error,
            attachment_id:,
            blob_id:,
            outcome: "failure_state_unavailable"
          )
          raise TransientVariantProcessingError,
            "vessel primary photo variant processing state unavailable",
            cause: nil
        end

        log_processing_failure(error, attachment_id:, blob_id:, outcome: "discarded_permanent")
        raise PermanentVariantProcessingError,
          "vessel primary photo variant is permanently unprocessable",
          cause: nil
      end

      log_processing_failure(error, attachment_id:, blob_id:, outcome: "retryable")
      raise TransientVariantProcessingError,
        "vessel primary photo variant processing failed transiently",
        cause: nil
    end

    def permanent_processing_error?(error)
      error.is_a?(ActiveStorage::InvariableError) ||
        error.is_a?(ActiveStorage::UnrepresentableError) ||
        (defined?(ImageProcessing::Error) && error.is_a?(ImageProcessing::Error)) ||
        (defined?(Vips::Error) && error.is_a?(Vips::Error))
    end

    def log_processing_failure(error, attachment_id:, blob_id:, outcome:)
      Rails.logger.error(
        "Vessel primary photo variant processing failed " \
          "attachment_id=#{attachment_id} blob_id=#{blob_id} outcome=#{outcome} " \
          "exception_class=#{error.class.name}"
      )
    end
  end
end
