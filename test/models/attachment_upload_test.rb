require "test_helper"

class AttachmentUploadTest < ActiveSupport::TestCase
  test "detected content type comes from bytes rather than an allowed filename" do
    upload = Rack::Test::UploadedFile.new(
      StringIO.new("plain text is not a JPEG"),
      "image/jpeg",
      true,
      original_filename: "misleading.jpg"
    )

    assert_equal "application/octet-stream", AttachmentUpload.detected_content_type(upload)
    assert_not AttachmentUpload.extension_matches_content_type?(upload)
  end

  test "content inspection preserves the upload IO position" do
    upload = Rack::Test::UploadedFile.new(file_fixture("sample.png"), "text/plain", true)
    upload.tempfile.read(10)
    original_position = upload.tempfile.pos

    assert_equal "image/png", AttachmentUpload.detected_content_type(upload)
    assert_equal original_position, upload.tempfile.pos
  end
end
