class AttachmentUpload
  def self.multipart?(upload)
    upload.is_a?(ActionDispatch::Http::UploadedFile) ||
      (defined?(Rack::Test::UploadedFile) && upload.is_a?(Rack::Test::UploadedFile))
  end
end
