class Document < ApplicationRecord
  DOCUMENT_TYPES = %w[insurance registration maintenance_record receipt marina_contract photo other].freeze
  ALLOWED_FILE_CONTENT_TYPES = %w[
    application/pdf
    image/jpeg
    image/png
    image/webp
  ].freeze
  MAX_FILE_SIZE = 25.megabytes

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
    return "must be a PDF, JPEG, PNG, or WEBP file" unless ALLOWED_FILE_CONTENT_TYPES.include?(file_upload_content_type(upload))

    "must be 25 MB or smaller" if file_upload_size(upload).to_i > MAX_FILE_SIZE
  end

  def self.file_upload_content_type(upload)
    io = file_upload_io(upload)

    return "" unless io

    current_position = io.pos if io.respond_to?(:pos)
    io.rewind if io.respond_to?(:rewind)

    Marcel::MimeType.for(
      io,
      name: file_upload_filename(upload)
    )
  ensure
    if io && current_position && io.respond_to?(:seek)
      io.seek(current_position)
    elsif io&.respond_to?(:rewind)
      io.rewind
    end
  end

  def self.file_upload_size(upload)
    return upload.size if upload.respond_to?(:size)
    return upload.tempfile.size if upload.respond_to?(:tempfile) && upload.tempfile.respond_to?(:size)

    0
  end

  def self.file_upload_io(upload)
    return upload.tempfile if upload.respond_to?(:tempfile) && upload.tempfile

    upload if upload.respond_to?(:read)
  end
  private_class_method :file_upload_io

  def self.file_upload_filename(upload)
    return upload.original_filename if upload.respond_to?(:original_filename)

    upload.path if upload.respond_to?(:path)
  end
  private_class_method :file_upload_filename

  private

  def asset_belongs_to_account
    return if asset.blank? || account_id.blank? || asset.account_id == account_id

    errors.add(:asset, "must belong to the selected owner")
  end

  def file_is_safe_upload
    return unless file.attached?

    unsafe_upload = false

    unless ALLOWED_FILE_CONTENT_TYPES.include?(file.blob.content_type.to_s)
      errors.add(:file, "must be a PDF, JPEG, PNG, or WEBP file")
      unsafe_upload = true
    end

    if file.blob.byte_size > MAX_FILE_SIZE
      errors.add(:file, "must be 25 MB or smaller")
      unsafe_upload = true
    end

    file.purge if unsafe_upload
  end
end
