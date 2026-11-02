module Storage
  class VesselPrimaryPhotoVariantJob < ApplicationJob
    queue_as :background

    PROCESSING_STATE_METADATA_KEY = "boat_binder_vessel_primary_photo_card_variant"
    PROCESSING_STATE_VERSION = 1
    PENDING_STATE = "pending"
    PERMANENT_FAILURE_STATE = "permanent_failure"
    VARIANT_NAMES = %i[card profile].freeze
    NO_REPLACEMENT = Object.new.freeze

    PermanentVariantProcessingError = Class.new(StandardError)
    TransientVariantProcessingError = Class.new(StandardError)

    retry_on TransientVariantProcessingError, wait: :polynomially_longer, attempts: 5
    discard_on PermanentVariantProcessingError

    limits_concurrency key: ->(attachment_id, _blob_id) { attachment_id },
      duration: 10.minutes,
      on_conflict: :discard

    class << self
      def enqueue_for(attachment, required_variant: :card, replace_job_id: NO_REPLACEMENT)
        return unless vessel_primary_photo_attachment?(attachment)

        state = status_for(attachment, variant: required_variant)
        return state unless state == :missing || replace_job_id != NO_REPLACEMENT

        blob = attachment.blob
        active_job = new(attachment.id, blob.id)
        claim_result = claim_processing(blob, job_id: active_job.job_id, replace_job_id:)
        return claim_result unless claim_result == :claimed

        enqueued_job = active_job.enqueue
        raise ActiveJob::EnqueueError, "photo variants could not be enqueued" unless enqueued_job&.successfully_enqueued?

        :pending
      rescue StandardError => error
        begin
          if blob && claim_result == :claimed
            clear_processing_state(blob, expected: PENDING_STATE, expected_job_id: active_job&.job_id)
          end
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

      def status_for(attachment, variant: :card, queue_state: :unknown)
        return :missing unless vessel_primary_photo_attachment?(attachment)

        image = attachment.variant(variant_name(variant)).image
        return :ready if image&.attached?

        state = processing_state(attachment.blob)
        return state unless state == :pending

        case queue_state
        when :failed
          :transient_failure
        when :missing, :finished
          :interrupted
        else
          :pending
        end
      end

      def queue_job_states_for(attachments)
        attachments = Array(attachments)
        job_ids_by_attachment = attachments.to_h do |attachment|
          [ attachment.id, processing_job_id(attachment.blob) ]
        end
        return job_ids_by_attachment.transform_values { :unknown } unless solid_queue_adapter?

        job_ids = job_ids_by_attachment.values.compact.uniq
        states_by_job_id = job_ids.index_with { :missing }
        if job_ids.any?
          jobs = SolidQueue::Job.includes(:failed_execution).where(
            active_job_id: job_ids,
            class_name: name
          )
          jobs.group_by(&:active_job_id).each do |active_job_id, matching_jobs|
            states_by_job_id[active_job_id] = if matching_jobs.any?(&:failed?)
              :failed
            elsif matching_jobs.any? { |job| !job.finished? }
              :active
            else
              :finished
            end
          end
        end

        job_ids_by_attachment.transform_values do |active_job_id|
          active_job_id ? states_by_job_id.fetch(active_job_id, :missing) : :missing
        end
      rescue StandardError => error
        Rails.logger.error(
          "Vessel primary photo variant queue state unavailable exception_class=#{error.class.name}"
        )
        attachments.to_h { |attachment| [ attachment.id, :unknown ] }
      end

      def recover_for(attachment, variant: :card, queue_state:)
        state = status_for(attachment, variant:, queue_state:)
        case state
        when :transient_failure
          retry_solid_queue_job(processing_job_id(attachment.blob)) ? :pending : :transient_failure
        when :interrupted
          enqueue_for(
            attachment,
            required_variant: variant,
            replace_job_id: processing_job_id(attachment.blob)
          )
        else
          state
        end
      end

      def mark_permanent_failure(blob, job_id:)
        write_processing_state(
          blob,
          PERMANENT_FAILURE_STATE,
          expected: PENDING_STATE,
          expected_job_id: job_id
        )
      end

      def ensure_pending_processing_state(blob, job_id:)
        result = :superseded
        blob.with_lock do
          current_state = processing_state(blob)
          current_job_id = processing_job_id(blob)
          if current_state == :missing || (current_state == :pending && current_job_id.nil?)
            write_processing_state_without_lock(blob, PENDING_STATE, job_id:)
            result = :pending
          elsif current_state == :pending && current_job_id == job_id
            result = :pending
          elsif current_state == :permanent_failure
            result = :permanent_failure
          end
        end
        result
      end

      def clear_processing_state(blob, expected: nil, expected_job_id: NO_REPLACEMENT)
        changed = false
        blob.with_lock do
          current_state = processing_state(blob)
          state_matches = expected.nil? || current_state == expected.to_sym
          job_matches = expected_job_id == NO_REPLACEMENT || processing_job_id(blob) == expected_job_id
          if state_matches && job_matches
            blob.update!(metadata: blob.metadata.except(PROCESSING_STATE_METADATA_KEY))
            changed = true
          end
        end
        changed
      end

      private

      def variant_name(name)
        name = name.to_sym
        raise ArgumentError, "unknown Vessel primary photo variant" unless name.in?(VARIANT_NAMES)

        name
      end

      def vessel_primary_photo_attachment?(attachment)
        return false unless attachment&.record_type == "Asset" && attachment.name == "primary_photo"

        attachment.record&.asset_type == "vessel"
      end

      def claim_processing(blob, job_id:, replace_job_id: NO_REPLACEMENT)
        result = processing_state(blob)
        blob.with_lock do
          current_state = processing_state(blob)
          replacement_matches = replace_job_id != NO_REPLACEMENT &&
            current_state == :pending &&
            processing_job_id(blob) == replace_job_id
          if current_state == :missing || replacement_matches
            write_processing_state_without_lock(blob, PENDING_STATE, job_id:)
            result = :claimed
          else
            result = current_state
          end
        end
        result
      end

      def write_processing_state(blob, state, expected: nil, expected_job_id: NO_REPLACEMENT)
        changed = false
        blob.with_lock do
          state_matches = expected.nil? || processing_state(blob) == expected.to_sym
          job_matches = expected_job_id == NO_REPLACEMENT || processing_job_id(blob) == expected_job_id
          if state_matches && job_matches
            write_processing_state_without_lock(blob, state)
            changed = true
          end
        end
        changed
      end

      def write_processing_state_without_lock(blob, state, job_id: nil)
        value = {
          "version" => PROCESSING_STATE_VERSION,
          "state" => state
        }
        value["job_id"] = job_id if job_id
        blob.update!(metadata: blob.metadata.merge(PROCESSING_STATE_METADATA_KEY => value))
      end

      def processing_state(blob)
        metadata = processing_metadata(blob)
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

      def processing_job_id(blob)
        metadata = processing_metadata(blob)
        metadata["job_id"].presence if metadata.is_a?(Hash)
      end

      def processing_metadata(blob)
        blob.metadata[PROCESSING_STATE_METADATA_KEY]
      end

      def solid_queue_adapter?
        defined?(SolidQueue::Job) &&
          ActiveJob::Base.queue_adapter.class.name == "ActiveJob::QueueAdapters::SolidQueueAdapter"
      end

      def retry_solid_queue_job(active_job_id)
        return false unless solid_queue_adapter? && active_job_id

        job = SolidQueue::Job.includes(:failed_execution)
          .where(active_job_id:, class_name: name)
          .order(id: :desc)
          .detect(&:failed?)
        return false unless job

        job.retry
        true
      rescue StandardError => error
        Rails.logger.error(
          "Vessel primary photo variant retry failed exception_class=#{error.class.name}"
        )
        false
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
      processing_state = self.class.ensure_pending_processing_state(blob, job_id: job_id)
      return if processing_state.in?([ :permanent_failure, :superseded ])

      unless attachment.record&.asset_type == "vessel"
        self.class.clear_processing_state(blob, expected: PENDING_STATE, expected_job_id: job_id)
        return
      end
      unless AttachmentScan.available_blob?(blob)
        self.class.clear_processing_state(blob, expected: PENDING_STATE, expected_job_id: job_id)
        return
      end

      if VARIANT_NAMES.all? { |name| attachment.variant(name).image&.attached? }
        self.class.clear_processing_state(blob, expected: PENDING_STATE, expected_job_id: job_id)
        return
      end
      unless ActiveStorage::Attachment.exists?(id: attachment_id, blob_id: blob_id)
        self.class.clear_processing_state(blob, expected: PENDING_STATE, expected_job_id: job_id)
        return
      end

      VARIANT_NAMES.each do |name|
        process_variant(attachment, name) unless attachment.variant(name).image&.attached?
      end
      self.class.clear_processing_state(blob, expected: PENDING_STATE, expected_job_id: job_id)
    rescue StandardError => error
      handle_processing_error(error, attachment_id:, blob_id:, blob:)
    end

    private

    def process_variant(attachment, name)
      attachment.variant(name).processed
    end

    def handle_processing_error(error, attachment_id:, blob_id:, blob: nil)
      if permanent_processing_error?(error, blob:, attachment_id:, blob_id:)
        begin
          self.class.mark_permanent_failure(blob, job_id:) if blob
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

    def permanent_processing_error?(error, blob:, attachment_id:, blob_id:)
      return true if error.is_a?(ActiveStorage::InvariableError) ||
        error.is_a?(ActiveStorage::UnrepresentableError)

      vips_error = defined?(Vips::Error) && error.is_a?(Vips::Error)
      return false unless vips_error

      source_blob_permanently_unprocessable?(blob, attachment_id:, blob_id:)
    end

    def source_blob_permanently_unprocessable?(blob, attachment_id:, blob_id:)
      return false unless blob && defined?(ImageProcessing::Vips)

      blob.open { |file| !ImageProcessing::Vips.valid_image?(file) }
    rescue StandardError => error
      log_processing_failure(
        error,
        attachment_id:,
        blob_id:,
        outcome: "classification_retryable"
      )
      false
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
