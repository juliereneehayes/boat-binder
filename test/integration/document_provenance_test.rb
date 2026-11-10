require "test_helper"

class DocumentProvenanceTest < ActionDispatch::IntegrationTest
  setup do
    @account = create_account(name: "Document provenance")
    @vessel = create_vessel(account: @account)
    @owner = create_user(email: "provenance-owner@example.test", role: "owner")
    @admin = create_user(email: "provenance-admin@example.test", role: "admin")
    create_account_membership(user: @owner, account: @account, access_level: "editor")
    ManagedServiceRelationship::Transition.call!(account: @account, active: true, actor: @admin)
  end

  test "authenticated author is assigned and own document can be reassigned replaced and deleted" do
    sign_in_as @owner
    post vessel_documents_path(@vessel), params: { document: {
      title: "Owner file", document_type: "other", created_by_user_id: @admin.id, author_kind: "professional",
      file: fixture_file_upload("sample.pdf", "application/pdf")
    } }
    document = Document.last
    assert_equal @owner, document.created_by_user
    assert_equal "owner", document.author_kind
    original_blob = document.file.blob.id
    second_vessel = create_vessel(account: @account, name: "Same Account vessel")
    patch document_path(document), params: { document: {
      title: "Updated", asset_id: second_vessel.id, created_by_user_id: @admin.id, author_kind: "professional",
      file: fixture_file_upload("sample.png", "image/png")
    } }
    assert_redirected_to vessel_path(second_vessel, anchor: "documents")
    assert_equal @owner.id, document.reload.created_by_user_id
    assert_equal "owner", document.author_kind
    assert_not_equal original_blob, document.file.blob.id
    assert_equal "pending", AttachmentScan.find_by!(active_storage_blob: document.file.blob).status
    delete vessel_document_path(@vessel, document)
    assert_response :not_found
    assert Document.exists?(document.id)
    assert_difference -> { Document.count }, -1 do
      delete vessel_document_path(second_vessel, document)
    end
  end

  test "professional other Owner and historical documents remain visible but immutable" do
    other_owner = create_user(email: "other-provenance@example.test", role: "owner")
    documents = [ @admin, other_owner, nil ].map do |author|
      document = @vessel.documents.create!(account: @account, created_by_user: author, title: "Protected", document_type: "other")
      document.file.attach(fixture_file_upload("sample.pdf", "application/pdf"))
      trust_attachment(document.file)
      document
    end
    # Current roles do not rewrite classification.
    @admin.update!(role: "owner")
    sign_in_as @owner
    documents.each do |document|
      original = document.reload.attributes
      blob_id = document.file.blob.id
      get document_path(document)
      assert_response :success
      assert_select "a[href=?]", edit_document_path(document), count: 0
      get document_file_path(document), params: { disposition: "attachment" }
      assert_response :success
      get edit_document_path(document)
      assert_redirected_to root_path
      patch document_path(document), params: { document: {
        title: "Blocked", asset_id: "", file: fixture_file_upload("sample.png", "image/png")
      } }
      assert_redirected_to root_path
      delete document_path(document)
      assert_redirected_to root_path
      assert_equal original, document.reload.attributes
      assert_equal blob_id, document.file.blob.id
      assert ActiveStorage::Blob.exists?(blob_id)
    end
    get documents_path
    documents.each { |document| assert_select "a[href=?]", edit_document_path(document), count: 0 }
    get vessel_path(@vessel)
    documents.each { |document| assert_select "a[href=?]", edit_document_path(document), count: 0 }
  end

  test "authorship cannot change after creation and classification ignores supplied kind" do
    document = Document.create!(account: @account, created_by_user: @admin, author_kind: "owner", title: "Professional", document_type: "other")
    assert_equal "professional", document.author_kind
    assert_not document.update(created_by_user: @owner, author_kind: "owner")
    assert_equal @admin, document.reload.created_by_user
    @admin.update!(role: "owner")
    document.update!(title: "Still professional")
    assert_equal "professional", document.reload.author_kind
  end

  test "internal Users retain management of unknown historical documents" do
    document = Document.create!(account: @account, title: "Historical", document_type: "other")
    [ @admin, create_user(email: "document-captain@example.test") ].each do |user|
      sign_in_as user
      get edit_document_path(document)
      assert_response :success
      patch document_path(document), params: { document: { title: user.role } }
      assert_equal user.role, document.reload.title
      assert_nil document.created_by_user_id
      assert_nil document.author_kind
    end
  end

  test "Self Managed Owner uses the same provenance permissions after revocation" do
    document = Document.create!(account: @account, created_by_user: @owner, title: "Retained", document_type: "other")
    ManagedServiceRelationship::Transition.call!(account: @account, active: false, actor: @admin)
    qualify_self_managed_subscription(@account)
    sign_in_as @owner
    patch document_path(document), params: { document: { title: "Still manageable" } }
    assert_equal "Still manageable", document.reload.title
    other = create_account(name: "Unrelated")
    vessel = create_vessel(account: other)
    patch document_path(document), params: { document: { asset_id: vessel.id } }
    assert_response :not_found
    assert_nil document.reload.asset_id
  end
end
