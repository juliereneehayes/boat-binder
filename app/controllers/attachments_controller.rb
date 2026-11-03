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

    case params[:presentation]
    when nil, ""
      deliver(vessel.primary_photo)
    when "card"
      deliver(vessel.primary_photo, variant: :card)
    when "profile"
      deliver(vessel.primary_photo, variant: :profile, fallback_to_source: true)
    else
      raise ActiveRecord::RecordNotFound
    end
  end

  def service_visit_photo
    vessel = scoped_vessels.find_by!(slug: params[:vessel_id])
    deny_inactive_account!(vessel.account)
    service_visit = vessel.service_visits.find(params[:service_visit_id])
    attachment = service_visit.photos.attachments.find(params[:id])

    deliver(attachment)
  end

  private

  def deliver(attachment, disposition: "inline", variant: nil, fallback_to_source: false)
    attachment = attachment.attachment if attachment.respond_to?(:attachment)
    raise ActiveRecord::RecordNotFound unless attachment

    source_blob = attachment.blob
    raise ActiveRecord::RecordNotFound unless AttachmentScan.available_blob?(source_blob)

    blob = if variant
      processed_variant_blob(attachment, variant, fallback: fallback_to_source ? source_blob : nil)
    else
      source_blob
    end

    response.headers["Accept-Ranges"] = "bytes"

    if request.headers["Range"].present?
      send_blob_byte_range_data(blob, request.headers["Range"], disposition:)
    else
      response.headers["Content-Length"] = blob.byte_size.to_s
      send_blob_stream(blob, disposition:)
    end
  end

  def processed_variant_blob(attachment, variant_name, fallback: nil)
    image = attachment.variant(variant_name).image
    return fallback if !image&.attached? && fallback
    raise ActiveRecord::RecordNotFound unless image&.attached?

    image.blob
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
