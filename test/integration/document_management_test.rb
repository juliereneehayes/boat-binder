require "test_helper"
require "tempfile"

class DocumentManagementTest < ActionDispatch::IntegrationTest
  test "vessel page includes direct document link and document can be deleted" do
    sign_in_as
    vessel = create_vessel
    document = vessel.documents.create!(account: vessel.account, title: "Insurance", document_type: "insurance")
    document.file.attach(io: StringIO.new("policy"), filename: "policy.pdf", content_type: "application/pdf")

    get vessel_path(vessel)
    assert_response :success
    assert_includes response.body, "Open file"
    assert_includes response.body, "Download"

    assert_difference -> { Document.count }, -1 do
      delete vessel_document_path(vessel, document)
    end
    assert_redirected_to vessel_path(vessel, anchor: "documents")
    assert_not Document.exists?(document.id)
  end

  test "vessel page renders six recent documents with attached and missing file controls" do
    sign_in_as
    vessel = create_vessel
    older_document = vessel.documents.create!(account: vessel.account, title: "Older document", document_type: "other", created_at: 8.days.ago)

    6.times do |index|
      document = vessel.documents.create!(
        account: vessel.account,
        title: "Recent document #{index + 1}",
        document_type: "other",
        created_at: (index + 1).hours.ago
      )
      document.file.attach(fixture_file_upload("sample.pdf", "application/pdf")) if index.even?
    end

    get vessel_path(vessel)

    assert_response :success
    assert_not_includes response.body, older_document.title
    assert_select "#documents a", text: /Recent document/, count: 6
    assert_includes response.body, "No file attached"
    assert_includes response.body, "Open file"
    assert_includes response.body, "Download"
    assert_select "#documents a[href^='/rails/active_storage']", minimum: 1
  end

  test "document index shows view edit and metadata only status" do
    account = create_account(name: "Elliott Family")
    vessel = create_vessel(account: account)
    document = vessel.documents.create!(account: account, title: "Metadata only", document_type: "insurance")
    attached_document = vessel.documents.create!(account: account, title: "Attached file", document_type: "registration")
    attached_document.file.attach(fixture_file_upload("sample.pdf", "application/pdf"))
    editor_owner = create_user(email: "document-index-editor@example.test", role: "owner")
    create_account_membership(user: editor_owner, account: account, access_level: "editor")
    sign_in_as editor_owner

    get documents_path

    assert_response :success
    assert_select "a[href=?]", document_path(document), text: "Metadata only"
    assert_select "a[href=?]", document_path(document), text: "View"
    assert_select "a[href=?]", edit_document_path(document), text: "Edit / Add file"
    assert_includes response.body, "No file attached"
    assert_select "a[href=?]", document_path(attached_document), text: "Attached file"
    assert_includes response.body, "Open file"
    assert_includes response.body, "Download"
  end

  test "owner editor can view and edit document metadata" do
    account = create_account(name: "Elliott Family")
    vessel = create_vessel(account: account)
    document = vessel.documents.create!(
      account: account,
      title: "Insurance binder",
      document_type: "insurance",
      notes: "Original notes."
    )
    editor_owner = create_user(email: "document-editor@example.test", role: "owner")
    create_account_membership(user: editor_owner, account: account, access_level: "editor")
    sign_in_as editor_owner

    get document_path(document)
    assert_response :success
    assert_includes response.body, "No file is currently attached."
    assert_select "a[href=?]", edit_document_path(document), text: "Edit / Add file"

    patch document_path(document), params: {
      document: {
        account_id: account.id,
        asset_id: vessel.id,
        title: "Updated insurance",
        document_type: "registration",
        notes: "Updated by owner editor."
      }
    }

    assert_redirected_to vessel_path(vessel, anchor: "documents")
    document.reload
    assert_equal "Updated insurance", document.title
    assert_equal "registration", document.document_type
    assert_equal "Updated by owner editor.", document.notes
    assert_not document.file.attached?
  end

  test "owner editor can attach a file to a metadata only document" do
    account = create_account(name: "Elliott Family")
    document = Document.create!(account: account, title: "Registration", document_type: "registration")
    editor_owner = create_user(email: "document-attach-editor@example.test", role: "owner")
    create_account_membership(user: editor_owner, account: account, access_level: "editor")
    sign_in_as editor_owner

    patch document_path(document), params: {
      document: {
        account_id: account.id,
        title: document.title,
        document_type: document.document_type,
        file: fixture_file_upload("sample.pdf", "application/pdf")
      }
    }

    assert_redirected_to document_path(document)
    assert document.reload.file.attached?
    assert_equal "application/pdf", document.file.blob.content_type
  end

  test "owner editor can replace an existing file and metadata updates preserve attachment" do
    account = create_account(name: "Elliott Family")
    document = Document.create!(account: account, title: "Receipt", document_type: "receipt")
    document.file.attach(fixture_file_upload("sample.pdf", "application/pdf"))
    original_blob_id = document.file.blob.id
    editor_owner = create_user(email: "document-replace-editor@example.test", role: "owner")
    create_account_membership(user: editor_owner, account: account, access_level: "editor")
    sign_in_as editor_owner

    patch document_path(document), params: {
      document: {
        account_id: account.id,
        title: "Receipt renamed",
        document_type: document.document_type,
        notes: "No replacement file selected."
      }
    }

    assert_redirected_to document_path(document)
    document.reload
    assert_equal "Receipt renamed", document.title
    assert_equal original_blob_id, document.file.blob.id

    patch document_path(document), params: {
      document: {
        account_id: account.id,
        title: document.title,
        document_type: document.document_type,
        file: fixture_file_upload("sample.png", "image/png")
      }
    }

    assert_redirected_to document_path(document)
    document.reload
    assert document.file.attached?
    assert_not_equal original_blob_id, document.file.blob.id
    assert_equal "image/png", document.file.blob.content_type
  end

  test "read only owner can view but cannot edit replace or delete documents" do
    account = create_account(name: "Elliott Family")
    document = Document.create!(account: account, title: "Read only document", document_type: "other")
    read_only_owner = create_user(email: "document-readonly@example.test", role: "owner")
    create_account_membership(user: read_only_owner, account: account, access_level: "read_only")
    sign_in_as read_only_owner

    get document_path(document)
    assert_response :success
    assert_select "a[href=?]", edit_document_path(document), count: 0

    get edit_document_path(document)
    assert_access_denied_redirect

    patch document_path(document), params: {
      document: {
        account_id: account.id,
        title: "Blocked",
        document_type: "other",
        file: fixture_file_upload("sample.pdf", "application/pdf")
      }
    }
    assert_access_denied_redirect

    assert_no_difference -> { Document.count } do
      delete document_path(document)
    end
    assert_access_denied_redirect
    assert_equal "Read only document", document.reload.title
    assert_not document.file.attached?
  end

  test "owner editor cannot view or mutate documents in another account" do
    account = create_account(name: "Elliott Family")
    other_account = create_account(name: "Harbor North")
    document = Document.create!(account: other_account, title: "Private document", document_type: "other")
    editor_owner = create_user(email: "document-scope-editor@example.test", role: "owner")
    create_account_membership(user: editor_owner, account: account, access_level: "editor")
    sign_in_as editor_owner

    get document_path(document)
    assert_response :not_found

    get edit_document_path(document)
    assert_response :not_found

    patch document_path(document), params: {
      document: {
        account_id: other_account.id,
        title: "Blocked",
        document_type: "other"
      }
    }
    assert_response :not_found

    delete document_path(document)
    assert_response :not_found
    assert Document.exists?(document.id)
  end

  test "crafted owner editor relationship requests cannot escape manageable accounts" do
    account = create_account(name: "Elliott Family")
    other_account = create_account(name: "Harbor North")
    vessel = create_vessel(account: account)
    other_vessel = create_vessel(account: other_account, name: "Restricted Vessel")
    document = vessel.documents.create!(account: account, title: "Managed document", document_type: "other")
    editor_owner = create_user(email: "document-crafted-editor@example.test", role: "owner")
    create_account_membership(user: editor_owner, account: account, access_level: "editor")
    sign_in_as editor_owner

    patch document_path(document), params: {
      document: {
        account_id: other_account.id,
        asset_id: other_vessel.id,
        title: "Crafted update",
        document_type: "other"
      }
    }

    assert_response :not_found
    document.reload
    assert_equal account, document.account
    assert_equal vessel, document.asset
    assert_equal "Managed document", document.title
  end

  test "invalid edit upload rerenders without replacing existing attachment" do
    account = create_account(name: "Elliott Family")
    document = Document.create!(account: account, title: "Safe file", document_type: "other")
    document.file.attach(fixture_file_upload("sample.pdf", "application/pdf"))
    original_blob_id = document.file.blob.id
    editor_owner = create_user(email: "document-invalid-editor@example.test", role: "owner")
    create_account_membership(user: editor_owner, account: account, access_level: "editor")
    sign_in_as editor_owner

    patch document_path(document), params: {
      document: {
        account_id: account.id,
        title: "Attempted bad replacement",
        document_type: "other",
        file: fixture_file_upload("sample.exe", "application/x-msdownload")
      }
    }

    assert_response :unprocessable_entity
    assert_includes response.body, "File must be a PDF, JPEG, PNG, or WEBP file"
    document.reload
    assert_equal "Safe file", document.title
    assert_equal original_blob_id, document.file.blob.id
  end

  test "oversized edit upload rerenders without replacing existing attachment" do
    account = create_account(name: "Elliott Family")
    document = Document.create!(account: account, title: "Sized file", document_type: "other")
    document.file.attach(fixture_file_upload("sample.pdf", "application/pdf"))
    original_blob_id = document.file.blob.id
    editor_owner = create_user(email: "document-oversized-editor@example.test", role: "owner")
    create_account_membership(user: editor_owner, account: account, access_level: "editor")
    oversized_file = Tempfile.new([ "oversized-edit", ".pdf" ])
    sign_in_as editor_owner

    begin
      oversized_file.binmode
      oversized_file.truncate(Document::MAX_FILE_SIZE + 1)
      oversized_file.rewind

      patch document_path(document), params: {
        document: {
          account_id: account.id,
          title: "Attempted oversized replacement",
          document_type: "other",
          file: Rack::Test::UploadedFile.new(oversized_file.path, "application/pdf", true)
        }
      }
    ensure
      oversized_file.close!
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "File must be 25 MB or smaller"
    document.reload
    assert_equal "Sized file", document.title
    assert_equal original_blob_id, document.file.blob.id
  end

  test "captain creates a document from main documents page and associates it with a vessel" do
    sign_in_as
    vessel = create_vessel

    get new_document_path
    assert_response :success
    assert_select "label", "Owner"
    assert_select "label", "Vessel"

    assert_difference -> { Document.count }, 1 do
      post documents_path, params: {
        document: {
          account_id: vessel.account_id,
          asset_id: vessel.id,
          title: "Updated insurance",
          document_type: "insurance",
          notes: "Uploaded from library.",
          file: fixture_file_upload("sample.pdf", "application/pdf")
        }
      }
    end

    document = Document.find_by!(title: "Updated insurance")
    assert_equal vessel, document.asset
    assert_equal vessel.account, document.account
    assert document.file.attached?
    assert_redirected_to vessel_path(vessel, anchor: "documents")
  end

  test "document relationship fields are permitted for create and update parsing" do
    sign_in_as
    vessel = create_vessel

    unpermitted_keys = capture_unpermitted_parameters do
      post documents_path, params: {
        document: {
          account_id: vessel.account_id,
          asset_id: vessel.id,
          title: "Parsed relationship fields",
          document_type: "insurance",
          notes: "Relationship fields should be authorized separately."
        }
      }
    end

    assert_empty unpermitted_keys
    document = Document.find_by!(title: "Parsed relationship fields")
    assert_equal vessel.account, document.account
    assert_equal vessel, document.asset

    unpermitted_keys = capture_unpermitted_parameters do
      patch document_path(document), params: {
        document: {
          account_id: vessel.account_id,
          asset_id: vessel.id,
          title: "Updated parsed relationship fields",
          document_type: "registration",
          notes: "Still parsed without direct mass assignment."
        }
      }
    end

    assert_empty unpermitted_keys
    document.reload
    assert_equal "Updated parsed relationship fields", document.title
    assert_equal "registration", document.document_type
    assert_equal vessel.account, document.account
    assert_equal vessel, document.asset
  end

  test "captain cannot create a document with mismatched owner and vessel" do
    sign_in_as
    account = create_account(name: "Elliott Family")
    other_vessel = create_vessel(account: create_account(name: "Harbor North"))

    assert_no_difference -> { Document.count } do
      post documents_path, params: {
        document: {
          account_id: account.id,
          asset_id: other_vessel.id,
          title: "Mismatched insurance",
          document_type: "insurance",
          file: fixture_file_upload("sample.pdf", "application/pdf")
        }
      }
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "must belong to the selected owner"
  end

  test "new document form filters vessels and disables double submit" do
    sign_in_as
    vessel = create_vessel

    get new_document_path

    assert_response :success
    assert_select "select[data-dependent-vessels-target='asset'] option[data-account-id='#{vessel.account_id}'][value='#{vessel.id}']", vessel.name
    assert_select "label[for='document_file']", "Choose document or photo"
    assert_select "input[type='file'][name='document[file]'][accept=?]", Document::ALLOWED_FILE_CONTENT_TYPES.join(",")
    assert_select "input[type='file'][name='document[file]'][capture]", count: 0
    assert_includes response.body, "choose a file, select a photo, or take a new photo"
    assert_includes response.body, "upload a PDF or image"
    assert_select "input[type=submit][data-turbo-submits-with=?]", "Uploading..."
  end

  test "document uploads accept allowed PDF and image content types" do
    sign_in_as
    vessel = create_vessel
    allowed_uploads = {
      "sample.pdf" => "application/pdf",
      "sample.jpg" => "image/jpeg",
      "sample.png" => "image/png",
      "sample.webp" => "image/webp"
    }

    allowed_uploads.each do |filename, content_type|
      assert_difference -> { Document.count }, 1 do
        post documents_path, params: {
          document: {
            account_id: vessel.account_id,
            asset_id: vessel.id,
            title: "Allowed #{content_type}",
            document_type: "other",
            file: fixture_file_upload(filename, content_type)
          }
        }
      end

      document = Document.find_by!(title: "Allowed #{content_type}")
      assert_equal content_type, document.file.blob.content_type
      assert_redirected_to vessel_path(vessel, anchor: "documents")
    end
  end

  test "document upload MIME detection uses file contents and preserves upload IO" do
    sign_in_as
    vessel = create_vessel
    upload = fixture_file_upload("sample.png", "text/plain")
    upload.tempfile.rewind
    upload.tempfile.read(10)
    original_position = upload.tempfile.pos
    assert_operator original_position, :>, 0

    assert_nil Document.file_upload_error(upload)
    assert_equal original_position, upload.tempfile.pos

    upload.tempfile.rewind

    assert_difference -> { Document.count }, 1 do
      post documents_path, params: {
        document: {
          account_id: vessel.account_id,
          asset_id: vessel.id,
          title: "Detected image upload",
          document_type: "other",
          file: upload
        }
      }
    end

    document = Document.find_by!(title: "Detected image upload")
    assert_equal "image/png", document.file.blob.content_type
    assert_redirected_to vessel_path(vessel, anchor: "documents")
  end

  test "document upload MIME detection preserves zero upload IO position" do
    upload = fixture_file_upload("sample.pdf", "application/pdf")
    upload.tempfile.rewind
    original_position = upload.tempfile.pos

    assert_equal 0, original_position
    assert_nil Document.file_upload_error(upload)
    assert_equal original_position, upload.tempfile.pos
  end

  test "unexpected file attachment failure rerenders new form safely" do
    sign_in_as
    vessel = create_vessel
    log_output = StringIO.new

    with_captured_logger(log_output) do
      with_failing_document_attachment(IOError.new("sensitive storage path /tmp/private-key")) do
        assert_no_difference -> { Document.count } do
          assert_no_difference -> { ActiveStorage::Blob.count } do
            assert_no_difference -> { ActiveStorage::Attachment.count } do
              post documents_path, params: {
                document: {
                  account_id: vessel.account_id,
                  asset_id: vessel.id,
                  title: "Failed attachment",
                  document_type: "other",
                  file: fixture_file_upload("sample.pdf", "application/pdf")
                }
              }
            end
          end
        end
      end
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "File could not be attached. Please try again."
    assert_not_includes response.body, "IOError"
    assert_not_includes response.body, "sensitive storage path"
    assert_includes log_output.string, "IOError"
    assert_includes log_output.string, "sensitive storage path"
  end

  test "unexpected file attachment failure rerenders edit form and preserves existing attachment" do
    account = create_account(name: "Elliott Family")
    document = Document.create!(account: account, title: "Existing document", document_type: "other")
    document.file.attach(fixture_file_upload("sample.pdf", "application/pdf"))
    original_blob_id = document.file.blob.id
    editor_owner = create_user(email: "document-attachment-failure@example.test", role: "owner")
    create_account_membership(user: editor_owner, account: account, access_level: "editor")
    log_output = StringIO.new
    sign_in_as editor_owner

    with_captured_logger(log_output) do
      with_failing_document_attachment(RuntimeError.new("storage bucket secret details")) do
        assert_no_difference -> { ActiveStorage::Attachment.count } do
          patch document_path(document), params: {
            document: {
              account_id: account.id,
              title: "Failed replacement",
              document_type: document.document_type,
              file: fixture_file_upload("sample.png", "image/png")
            }
          }
        end
      end
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "File could not be attached. Please try again."
    assert_not_includes response.body, "RuntimeError"
    assert_not_includes response.body, "storage bucket secret details"
    assert_includes log_output.string, "RuntimeError"
    assert_includes log_output.string, "storage bucket secret details"

    document.reload
    assert_equal "Existing document", document.title
    assert_equal original_blob_id, document.file.blob.id
  end

  test "document uploads reject spoofed allowed content types" do
    sign_in_as
    vessel = create_vessel

    assert_no_difference -> { Document.count } do
      assert_no_difference -> { ActiveStorage::Blob.count } do
        assert_no_difference -> { ActiveStorage::Attachment.count } do
          post documents_path, params: {
            document: {
              account_id: vessel.account_id,
              asset_id: vessel.id,
              title: "Spoofed executable",
              document_type: "other",
              file: fixture_file_upload("sample.exe", "image/jpeg")
            }
          }
        end
      end
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "File must be a PDF, JPEG, PNG, or WEBP file"
  end

  test "document uploads reject executable and unknown content types" do
    sign_in_as
    vessel = create_vessel
    rejected_uploads = {
      "sample.exe" => "application/x-msdownload",
      "sample.bin" => "application/octet-stream"
    }

    rejected_uploads.each do |filename, content_type|
      assert_no_difference -> { Document.count } do
        assert_no_difference -> { ActiveStorage::Blob.count } do
          assert_no_difference -> { ActiveStorage::Attachment.count } do
            post documents_path, params: {
              document: {
                account_id: vessel.account_id,
                asset_id: vessel.id,
                title: "Rejected #{content_type}",
                document_type: "other",
                file: fixture_file_upload(filename, content_type)
              }
            }
          end
        end
      end

      assert_response :unprocessable_entity
      assert_includes response.body, "File must be a PDF, JPEG, PNG, or WEBP file"
    end
  end

  test "document uploads reject files over the size limit" do
    sign_in_as
    vessel = create_vessel
    oversized_file = Tempfile.new([ "oversized", ".pdf" ])

    begin
      oversized_file.binmode
      oversized_file.truncate(Document::MAX_FILE_SIZE + 1)
      oversized_file.rewind

      assert_no_difference -> { Document.count } do
        assert_no_difference -> { ActiveStorage::Blob.count } do
          assert_no_difference -> { ActiveStorage::Attachment.count } do
            post documents_path, params: {
              document: {
                account_id: vessel.account_id,
                asset_id: vessel.id,
                title: "Oversized upload",
                document_type: "other",
                file: Rack::Test::UploadedFile.new(oversized_file.path, "application/pdf", true)
              }
            }
          end
        end
      end
    ensure
      oversized_file.close!
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "File must be 25 MB or smaller"
  end

  test "owner role cannot assign a new document to a vessel" do
    vessel = create_vessel
    sign_in_as create_user(email: "owner@example.test", role: "owner")

    assert_no_difference -> { Document.count } do
      post documents_path, params: {
        document: {
          account_id: vessel.account_id,
          asset_id: vessel.id,
          title: "Private upload",
          document_type: "insurance"
        }
      }
    end

    assert_redirected_to root_path
    follow_redirect!
    assert_includes response.body, Authorization::ACCESS_DENIED_MESSAGE
  end

  private

  def with_captured_logger(output)
    original_logger = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(output)
    yield
  ensure
    Rails.logger = original_logger
  end

  def with_failing_document_attachment(error)
    attached_one = ActiveStorage::Attached::One
    original_attach = attached_one.instance_method(:attach)
    attached_one.define_method(:attach) do |_attachable|
      raise error
    end

    yield
  ensure
    attached_one.define_method(:attach, original_attach)
  end

  def capture_unpermitted_parameters
    original_behavior = ActionController::Parameters.action_on_unpermitted_parameters
    ActionController::Parameters.action_on_unpermitted_parameters = :log
    keys = []
    callback = lambda do |_name, _started, _finished, _unique_id, payload|
      keys.concat(Array(payload[:keys]).map(&:to_s))
    end

    ActiveSupport::Notifications.subscribed(callback, "unpermitted_parameters.action_controller") do
      yield
    end

    keys
  ensure
    ActionController::Parameters.action_on_unpermitted_parameters = original_behavior
  end
end
