require "test_helper"

module Storage
  class VesselPrimaryPhotoVariantJobTest < ActiveJob::TestCase
    setup do
      @vessel = create_vessel
      attach_fixture(@vessel, "sample.jpg", "image/jpeg")
      @attachment = @vessel.primary_photo.attachment
      @blob = @attachment.blob
      clear_enqueued_jobs
    end

    teardown do
      clear_enqueued_jobs
    end

    test "processes card and profile variants only for an approved current Vessel photo" do
      trust_attachment(@vessel.primary_photo)

      assert_difference -> { ActiveStorage::VariantRecord.count }, 2 do
        VesselPrimaryPhotoVariantJob.perform_now(@attachment.id, @blob.id)
      end

      {
        card: [ Asset::PRIMARY_PHOTO_CARD_WIDTH, Asset::PRIMARY_PHOTO_CARD_HEIGHT ],
        profile: [ Asset::PRIMARY_PHOTO_PROFILE_WIDTH, Asset::PRIMARY_PHOTO_PROFILE_HEIGHT ]
      }.each do |name, dimensions|
        image = @attachment.variant(name).image
        assert image.attached?
        assert_equal "image/webp", image.blob.content_type
        processed_image = Vips::Image.new_from_buffer(image.blob.download, "")
        assert_equal dimensions, [ processed_image.width, processed_image.height ]
      end

      assert_no_difference -> { ActiveStorage::VariantRecord.count } do
        VesselPrimaryPhotoVariantJob.perform_now(@attachment.id, @blob.id)
      end
    end

    test "an existing card variant queues the shared job once when the profile variant is missing" do
      trust_attachment(@vessel.primary_photo)
      @attachment.variant(:card).processed

      assert_enqueued_jobs 1, only: VesselPrimaryPhotoVariantJob do
        assert_equal :pending,
          VesselPrimaryPhotoVariantJob.enqueue_for(@attachment, required_variant: :profile)
        assert_equal :pending,
          VesselPrimaryPhotoVariantJob.enqueue_for(@attachment, required_variant: :profile)
      end

      assert_equal :ready, VesselPrimaryPhotoVariantJob.status_for(@attachment, variant: :card)
      assert_equal :pending, VesselPrimaryPhotoVariantJob.status_for(@attachment, variant: :profile)
    end

    test "does not process unavailable scan states" do
      %w[pending rejected failed].each do |status|
        scan = AttachmentScan.create!(
          active_storage_blob: @blob,
          status:,
          provider: AttachmentScan::PROVIDER,
          completed_at: status == "pending" ? nil : Time.current,
          status_code: { "rejected" => "THREATS_FOUND", "failed" => "FAILED" }[status]
        )
        clear_enqueued_jobs

        assert_no_difference -> { ActiveStorage::VariantRecord.count } do
          VesselPrimaryPhotoVariantJob.perform_now(@attachment.id, @blob.id)
        end

        scan.delete
      end

      assert_no_difference -> { ActiveStorage::VariantRecord.count } do
        VesselPrimaryPhotoVariantJob.perform_now(@attachment.id, @blob.id)
      end
    end

    test "clean scan completion enqueues one variant job for a Vessel photo" do
      scan = AttachmentScan.register_pending!(@blob)
      clear_enqueued_jobs

      assert_enqueued_with(
        job: VesselPrimaryPhotoVariantJob,
        args: [ @attachment.id, @blob.id ]
      ) do
        scan.mark_clean!
      end
      assert_equal :pending, VesselPrimaryPhotoVariantJob.status_for(@attachment.reload)

      assert_no_enqueued_jobs only: VesselPrimaryPhotoVariantJob do
        scan.mark_clean!
      end
    end

    test "duplicate submissions create one job and one persistent processing claim" do
      trust_attachment(@vessel.primary_photo)

      assert_enqueued_jobs 1, only: VesselPrimaryPhotoVariantJob do
        assert_equal :pending, VesselPrimaryPhotoVariantJob.enqueue_for(@attachment)
        assert_equal :pending, VesselPrimaryPhotoVariantJob.enqueue_for(@attachment)
      end

      assert_equal :pending, VesselPrimaryPhotoVariantJob.status_for(@attachment)
      state = @blob.reload.metadata.fetch(VesselPrimaryPhotoVariantJob::PROCESSING_STATE_METADATA_KEY)
      assert_equal VesselPrimaryPhotoVariantJob::PROCESSING_STATE_VERSION, state.fetch("version")
      assert_equal VesselPrimaryPhotoVariantJob::PENDING_STATE, state.fetch("state")
      assert_predicate state.fetch("job_id"), :present?
    end

    test "a missing queue job is replaced once without disturbing active work" do
      trust_attachment(@vessel.primary_photo)
      assert_equal :pending, VesselPrimaryPhotoVariantJob.enqueue_for(@attachment)
      original_job_id = processing_job_id(@blob.reload)
      clear_enqueued_jobs

      assert_enqueued_jobs 1, only: VesselPrimaryPhotoVariantJob do
        assert_equal :pending,
          VesselPrimaryPhotoVariantJob.recover_for(@attachment.reload, queue_state: :missing)
      end

      replacement_job_id = processing_job_id(@blob.reload)
      assert_not_equal original_job_id, replacement_job_id

      clear_enqueued_jobs
      assert_no_enqueued_jobs only: VesselPrimaryPhotoVariantJob do
        assert_equal :pending,
          VesselPrimaryPhotoVariantJob.recover_for(@attachment.reload, queue_state: :active)
      end
      assert_equal replacement_job_id, processing_job_id(@blob.reload)
    end

    test "an exhausted transient job is retried in place without creating a new job" do
      trust_attachment(@vessel.primary_photo)
      assert_equal :pending, VesselPrimaryPhotoVariantJob.enqueue_for(@attachment)
      active_job_id = processing_job_id(@blob.reload)
      clear_enqueued_jobs
      retried_job_ids = []

      with_replaced_singleton_method(
        VesselPrimaryPhotoVariantJob,
        :retry_solid_queue_job,
        ->(job_id) { retried_job_ids << job_id; true }
      ) do
        assert_no_enqueued_jobs only: VesselPrimaryPhotoVariantJob do
          assert_equal :pending,
            VesselPrimaryPhotoVariantJob.recover_for(@attachment.reload, queue_state: :failed)
        end
      end

      assert_equal [ active_job_id ], retried_job_ids
      assert_equal active_job_id, processing_job_id(@blob.reload)
    end

    test "queue state lookup distinguishes active and exhausted Solid Queue work" do
      trust_attachment(@vessel.primary_photo)
      assert_equal :pending, VesselPrimaryPhotoVariantJob.enqueue_for(@attachment)
      active_job_id = processing_job_id(@blob.reload)
      clear_enqueued_jobs
      solid_job = SolidQueue::Job.create!(
        active_job_id:,
        class_name: VesselPrimaryPhotoVariantJob.name,
        queue_name: "background",
        arguments: {},
        scheduled_at: Time.current
      )

      with_replaced_singleton_method(VesselPrimaryPhotoVariantJob, :solid_queue_adapter?, -> { true }) do
        states = VesselPrimaryPhotoVariantJob.queue_job_states_for([ @attachment.reload ])
        assert_equal :active, states.fetch(@attachment.id)

        solid_job.ready_execution.destroy!
        SolidQueue::FailedExecution.create!(
          job: solid_job,
          error: {
            "exception_class" => VesselPrimaryPhotoVariantJob::TransientVariantProcessingError.name,
            "message" => "sanitized test failure",
            "backtrace" => []
          }
        )

        states = VesselPrimaryPhotoVariantJob.queue_job_states_for([ @attachment.reload ])
        assert_equal :failed, states.fetch(@attachment.id)
      end
    end

    test "non Vessel primary photos do not create variant jobs" do
      non_vessel = create_vessel(name: "Non Vessel Photo Asset")
      non_vessel.update!(asset_type: "home")
      attach_fixture(non_vessel, "sample.jpg", "image/jpeg")
      attachment = non_vessel.primary_photo.attachment

      assert_no_enqueued_jobs only: VesselPrimaryPhotoVariantJob do
        assert_nil VesselPrimaryPhotoVariantJob.enqueue_for(attachment)
      end
      assert_not attachment.blob.reload.metadata.key?(VesselPrimaryPhotoVariantJob::PROCESSING_STATE_METADATA_KEY)
    end

    test "superseded attachment jobs exit without processing the old blob" do
      trust_attachment(@vessel.primary_photo)
      old_attachment_id = @attachment.id
      old_blob_id = @blob.id

      attach_fixture(@vessel, "sample.png", "image/png")

      assert_no_difference -> { ActiveStorage::VariantRecord.count } do
        VesselPrimaryPhotoVariantJob.perform_now(old_attachment_id, old_blob_id)
      end
    end

    test "permanent processing failures are discarded and expose only sanitized details" do
      @vessel.primary_photo.purge
      @vessel.primary_photo.attach(
        io: StringIO.new("not an image"),
        filename: "invalid.jpg",
        content_type: "image/jpeg"
      )
      @attachment = @vessel.primary_photo.attachment
      @blob = @attachment.blob
      trust_attachment(@vessel.primary_photo)
      assert_equal :pending, VesselPrimaryPhotoVariantJob.enqueue_for(@attachment)
      clear_enqueued_jobs

      logs = capture_logs do
        assert_no_enqueued_jobs only: VesselPrimaryPhotoVariantJob do
          claimed_job(@attachment, @blob).perform_now
        end
      end

      assert_equal :permanent_failure, VesselPrimaryPhotoVariantJob.status_for(@attachment.reload)
      assert_includes logs, "attachment_id=#{@attachment.id}"
      assert_includes logs, "blob_id=#{@blob.id}"
      assert_includes logs, "outcome=discarded_permanent"
      assert_includes logs, "exception_class="
      assert_not_includes logs, @blob.filename.to_s
      assert_not_includes logs, @blob.key
    end

    test "transient processing failures retry and later recovery clears the claim" do
      trust_attachment(@vessel.primary_photo)
      assert_equal :pending, VesselPrimaryPhotoVariantJob.enqueue_for(@attachment)
      clear_enqueued_jobs

      with_replaced_instance_method(
        VesselPrimaryPhotoVariantJob,
        :process_variant,
        ->(_attachment, _name) { raise IOError, "synthetic storage outage" }
      ) do
        assert_enqueued_with(
          job: VesselPrimaryPhotoVariantJob,
          args: [ @attachment.id, @blob.id ]
        ) do
          claimed_job(@attachment, @blob).perform_now
        end
      end

      assert_equal :pending, VesselPrimaryPhotoVariantJob.status_for(@attachment)
      clear_enqueued_jobs

      claimed_job(@attachment, @blob).perform_now

      assert_equal :ready, VesselPrimaryPhotoVariantJob.status_for(@attachment.reload)
      assert_not @blob.reload.metadata.key?(VesselPrimaryPhotoVariantJob::PROCESSING_STATE_METADATA_KEY)
    end

    test "broad image processor errors stay recoverable when the source is valid" do
      job = VesselPrimaryPhotoVariantJob.new(@attachment.id, @blob.id)

      [ Vips::Error.new("synthetic vips environment error"), ImageProcessing::Error.new("synthetic pipeline error") ].each do |error|
        assert_not job.send(
          :permanent_processing_error?,
          error,
          blob: @blob,
          attachment_id: @attachment.id,
          blob_id: @blob.id
        )
      end
    end

    private

    def attach_fixture(vessel, filename, content_type)
      file_fixture(filename).open do |file|
        vessel.primary_photo.attach(io: file, filename:, content_type:)
      end
    end

    def capture_logs
      output = StringIO.new
      original_logger = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(output)
      yield
      output.string
    ensure
      Rails.logger = original_logger
    end

    def claimed_job(attachment, blob)
      VesselPrimaryPhotoVariantJob.new(attachment.id, blob.id).tap do |job|
        job.job_id = processing_job_id(blob.reload)
      end
    end

    def processing_job_id(blob)
      blob.metadata.fetch(VesselPrimaryPhotoVariantJob::PROCESSING_STATE_METADATA_KEY).fetch("job_id")
    end

    def with_replaced_instance_method(receiver, method_name, replacement)
      original = receiver.instance_method(method_name)
      receiver.define_method(method_name, replacement)
      receiver.send(:private, method_name)
      yield
    ensure
      receiver.define_method(method_name, original)
      receiver.send(:private, method_name)
    end

    def with_replaced_singleton_method(receiver, method_name, replacement)
      singleton_class = receiver.singleton_class
      original = singleton_class.instance_method(method_name)
      singleton_class.define_method(method_name, replacement)
      yield
    ensure
      singleton_class.define_method(method_name, original)
      singleton_class.send(:private, method_name)
    end
  end
end
