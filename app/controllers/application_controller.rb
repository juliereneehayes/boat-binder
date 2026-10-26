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
end
