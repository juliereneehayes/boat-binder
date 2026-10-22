require "test_helper"

class DocumentTest < ActiveSupport::TestCase
  test "asset is optional for binder-wide documents" do
    document = Document.new(account: create_account, title: "Insurance", document_type: "insurance")

    assert document.valid?
  end

  test "requires known document type" do
    document = Document.new(account: create_account, title: "Mystery", document_type: "unknown")

    assert_not document.valid?
    assert_includes document.errors[:document_type], "is not included in the list"
  end

  test "asset must belong to selected account" do
    account = create_account(name: "Elliott Family")
    other_account = create_account(name: "Harbor North")
    vessel = create_vessel(account: other_account)

    document = Document.new(account: account, asset: vessel, title: "Insurance", document_type: "insurance")

    assert_not document.valid?
    assert_includes document.errors[:asset], "must belong to the selected owner"
  end

  test "unsafe upload is purged from unsaved document during validation" do
    document = Document.new(account: create_account, title: "Unsafe upload", document_type: "other")

    assert_no_difference -> { ActiveStorage::Blob.count } do
      assert_no_difference -> { ActiveStorage::Attachment.count } do
        document.file.attach(io: StringIO.new("unsafe"), filename: "unsafe.exe", content_type: "application/x-msdownload")

        assert document.file.attached?
        assert_not document.valid?
        assert_not document.file.attached?
      end
    end

    assert_includes document.errors[:file], "must be a PDF, JPEG, PNG, or WEBP file"
  end

  test "metadata edits preserve a legacy attachment with a mismatched extension" do
    document = Document.create!(account: create_account, title: "Legacy", document_type: "other")
    blob = ActiveStorage::Blob.create_and_upload!(
      io: file_fixture("sample.jpg").open,
      filename: "legacy.bin",
      content_type: "image/jpeg",
      identify: false
    )
    ActiveStorage::Attachment.create!(name: "file", record: document, blob:)

    document.update!(title: "Legacy renamed")

    assert_equal blob.id, document.reload.file.blob.id
  end
end
