class AttachmentsController < ApplicationController
  include ActiveStorage::Streaming

  before_action :prevent_protected_content_caching

  def document_file
    document = scoped_documents.with_attached_file.find(params[:document_id])
    deny_inactive_account!(document.account)

    deliver(document.file, disposition: requested_document_disposition)
  end

  def vessel_primary_photo
    vessel = scoped_vessels.with_attached_primary_photo.find_by!(slug: params[:vessel_id])
    deny_inactive_account!(vessel.account)

    deliver(vessel.primary_photo)
  end

  def service_visit_photo
    vessel = scoped_vessels.find_by!(slug: params[:vessel_id])
    deny_inactive_account!(vessel.account)
    service_visit = vessel.service_visits.find(params[:service_visit_id])
    attachment = service_visit.photos.attachments.find(params[:id])

    deliver(attachment)
  end

  private

  def deliver(attachment, disposition: "inline")
    attachment = attachment.attachment if attachment.respond_to?(:attachment)
    raise ActiveRecord::RecordNotFound unless attachment

    blob = attachment.blob
    response.headers["Accept-Ranges"] = "bytes"
    response.headers["Content-Length"] = blob.byte_size.to_s

    if request.headers["Range"].present?
      send_blob_byte_range_data(blob, request.headers["Range"], disposition:)
    else
      send_blob_stream(blob, disposition:)
    end
  end

  def requested_document_disposition
    params[:disposition] == "attachment" ? "attachment" : "inline"
  end

  def deny_inactive_account!(account)
    raise ActiveRecord::RecordNotFound unless account.active?
  end

  def prevent_protected_content_caching
    response.headers["Cache-Control"] = "private, no-store, max-age=0"
    response.headers["Pragma"] = "no-cache"
    response.headers["X-Content-Type-Options"] = "nosniff"
  end
end
