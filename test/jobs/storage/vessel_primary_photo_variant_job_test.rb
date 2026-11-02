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

    test "processes the card variant only for an approved current Vessel photo" do
      trust_attachment(@vessel.primary_photo)

      assert_difference -> { ActiveStorage::VariantRecord.count }, 1 do
        VesselPrimaryPhotoVariantJob.perform_now(@attachment.id, @blob.id)
      end

      image = @attachment.variant(:card).image
      assert image.attached?
      assert_equal "image/webp", image.blob.content_type
      processed_image = Vips::Image.new_from_buffer(image.blob.download, "")
      assert_equal Asset::PRIMARY_PHOTO_CARD_WIDTH, processed_image.width
      assert_equal Asset::PRIMARY_PHOTO_CARD_HEIGHT, processed_image.height

      assert_no_difference -> { ActiveStorage::VariantRecord.count } do
        VesselPrimaryPhotoVariantJob.perform_now(@attachment.id, @blob.id)
      end
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

      assert_no_enqueued_jobs only: VesselPrimaryPhotoVariantJob do
        scan.mark_clean!
      end
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

    test "processing failures expose only safe identifiers and exception class" do
      @vessel.primary_photo.purge
      @vessel.primary_photo.attach(
        io: StringIO.new("not an image"),
        filename: "invalid.jpg",
        content_type: "image/jpeg"
      )
      @attachment = @vessel.primary_photo.attachment
      @blob = @attachment.blob
      trust_attachment(@vessel.primary_photo)

      logs = capture_logs do
        assert_raises(VesselPrimaryPhotoVariantJob::VariantProcessingError) do
          VesselPrimaryPhotoVariantJob.perform_now(@attachment.id, @blob.id)
        end
      end

      assert_includes logs, "attachment_id=#{@attachment.id}"
      assert_includes logs, "blob_id=#{@blob.id}"
      assert_includes logs, "exception_class="
      assert_not_includes logs, @blob.filename.to_s
      assert_not_includes logs, @blob.key
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
  end
end
