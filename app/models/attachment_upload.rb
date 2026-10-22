class AttachmentUpload
  EXTENSIONS_BY_CONTENT_TYPE = {
    "application/pdf" => %w[pdf],
    "image/jpeg" => %w[jpg jpeg],
    "image/png" => %w[png],
    "image/webp" => %w[webp]
  }.freeze

  def self.multipart?(upload)
    upload.is_a?(ActionDispatch::Http::UploadedFile) ||
      (defined?(Rack::Test::UploadedFile) && upload.is_a?(Rack::Test::UploadedFile))
  end

  def self.io(upload)
    return upload.tempfile if upload.respond_to?(:tempfile) && upload.tempfile

    upload if upload.respond_to?(:read)
  end

  def self.filename(upload)
    return upload.original_filename if upload.respond_to?(:original_filename)
    return upload.filename.to_s if upload.respond_to?(:filename)

    upload.path if upload.respond_to?(:path)
  end

  def self.extension(upload)
    filename(upload).to_s.downcase[/\.([a-z0-9]+)\z/, 1].to_s
  end

  def self.byte_size(upload)
    return upload.size if upload.respond_to?(:size)
    return upload.tempfile.size if upload.respond_to?(:tempfile) && upload.tempfile.respond_to?(:size)

    0
  end

  def self.detected_content_type(upload)
    upload_io = io(upload)
    return "" unless upload_io

    current_position = upload_io.pos if upload_io.respond_to?(:pos)
    upload_io.rewind if upload_io.respond_to?(:rewind)

    Marcel::MimeType.for(upload_io)
  ensure
    if upload_io && !current_position.nil? && upload_io.respond_to?(:seek)
      upload_io.seek(current_position)
    elsif upload_io&.respond_to?(:rewind)
      upload_io.rewind
    end
  end

  def self.extension_matches_content_type?(upload, content_type = detected_content_type(upload))
    EXTENSIONS_BY_CONTENT_TYPE.fetch(content_type.to_s, []).include?(extension(upload))
  end
end
