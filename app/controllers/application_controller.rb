class ApplicationController < ActionController::Base
  include Authentication
  include Authorization
  include AccountTimeZoneContext

  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  private

  def preload_attachment_scans(*attachments)
    blob_ids = attachments.flatten.filter_map do |attachment|
      attachment = attachment.attachment if attachment.respond_to?(:attachment)
      attachment&.blob_id
    end.uniq
    return if blob_ids.empty?

    @attachment_scan_cache ||= {}
    missing_blob_ids = blob_ids.reject { |blob_id| @attachment_scan_cache.key?(blob_id) }
    return if missing_blob_ids.empty?

    missing_blob_ids.each { |blob_id| @attachment_scan_cache[blob_id] = nil }
    AttachmentScan.where(active_storage_blob_id: missing_blob_ids).find_each do |scan|
      @attachment_scan_cache[scan.active_storage_blob_id] = scan
    end
  end

  def prepare_vessel_primary_photo_card_variants(vessels)
    @vessel_primary_photo_card_states = {}
    attachments = Array(vessels).filter_map { |vessel| vessel.primary_photo.attachment }
    queue_states = Storage::VesselPrimaryPhotoVariantJob.queue_job_states_for(attachments)
    recover_processing = params[:photo_status_check] == "1"

    attachments.each do |attachment|
      queue_state = queue_states.fetch(attachment.id, :unknown)
      state = if @attachment_scan_cache&.fetch(attachment.blob_id, nil)&.available?
        Storage::VesselPrimaryPhotoVariantJob.status_for(attachment, queue_state:).then do |current_state|
          if current_state == :missing
            Storage::VesselPrimaryPhotoVariantJob.enqueue_for(attachment)
          elsif recover_processing
            Storage::VesselPrimaryPhotoVariantJob.recover_for(attachment, queue_state:)
          else
            current_state
          end
        end
      else
        Storage::VesselPrimaryPhotoVariantJob.status_for(attachment, queue_state:)
      end
      @vessel_primary_photo_card_states[attachment.id] = state
    end
  end

  def prepare_vessel_primary_photo_profile_variant(vessel)
    attachment = vessel.primary_photo.attachment
    return unless attachment
    return unless @attachment_scan_cache&.fetch(attachment.blob_id, nil)&.available?
    return if attachment.variant(:profile).image&.attached?

    queue_state = Storage::VesselPrimaryPhotoVariantJob.queue_job_states_for([ attachment ])
      .fetch(attachment.id, :unknown)
    state = Storage::VesselPrimaryPhotoVariantJob.status_for(
      attachment,
      variant: :profile,
      queue_state:
    )

    if state == :missing
      Storage::VesselPrimaryPhotoVariantJob.enqueue_for(attachment, required_variant: :profile)
    elsif state == :interrupted
      Storage::VesselPrimaryPhotoVariantJob.recover_for(
        attachment,
        variant: :profile,
        queue_state:
      )
    end
  end
end
