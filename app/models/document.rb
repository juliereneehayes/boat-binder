class Document < ApplicationRecord
  DOCUMENT_TYPES = %w[insurance registration maintenance_record receipt marina_contract photo other].freeze
  ALLOWED_FILE_CONTENT_TYPES = %w[
    application/pdf
    image/jpeg
    image/png
    image/webp
  ].freeze
  MAX_FILE_SIZE = 25.megabytes
  FILE_EXTENSION_ERROR = "extension does not match the uploaded file type"

  belongs_to :account
  belongs_to :asset, optional: true
  has_one_attached :file

  validates :title, presence: true, length: { maximum: 120 }
  validates :notes, length: { maximum: 2_000 }
  validates :document_type, inclusion: { in: DOCUMENT_TYPES }
  validate :asset_belongs_to_account
  validate :file_is_safe_upload

  def self.file_upload_error(upload)
    return if upload.blank?
    return "must be a new file uploaded from this device" unless AttachmentUpload.multipart?(upload)
    return "must be 25 MB or smaller" if AttachmentUpload.byte_size(upload).to_i > MAX_FILE_SIZE

    detected_content_type = AttachmentUpload.detected_content_type(upload)
    return "must be a PDF, JPEG, PNG, or WEBP file" unless ALLOWED_FILE_CONTENT_TYPES.include?(detected_content_type)
    FILE_EXTENSION_ERROR unless AttachmentUpload.extension_matches_content_type?(upload, detected_content_type)
  end

  private

  def asset_belongs_to_account
    return if asset.blank? || account_id.blank? || asset.account_id == account_id

    errors.add(:asset, "must belong to the selected owner")
  end

  def file_is_safe_upload
    return unless file.attached? && file.attachment.new_record?

    unsafe_upload = false

    unless ALLOWED_FILE_CONTENT_TYPES.include?(file.blob.content_type.to_s)
      errors.add(:file, "must be a PDF, JPEG, PNG, or WEBP file")
      unsafe_upload = true
    end

    unless AttachmentUpload.extension_matches_content_type?(file.blob, file.blob.content_type)
      errors.add(:file, FILE_EXTENSION_ERROR)
      unsafe_upload = true
    end

    if file.blob.byte_size > MAX_FILE_SIZE
      errors.add(:file, "must be 25 MB or smaller")
      unsafe_upload = true
    end

    file.purge if unsafe_upload
  end
end
