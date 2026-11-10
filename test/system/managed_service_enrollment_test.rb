require "application_system_test_case"

class ManagedServiceEnrollmentTest < ApplicationSystemTestCase
  test "Admin enrolls and revokes from the existing Owner page" do
    account = create_account(name: "Enrollment Account")
    admin = create_user(email: "enrollment-admin@example.test", role: "admin")
    sign_in_with_browser(admin)
    visit owner_path(account)
    assert_text "HYC Managed Service"
    assert_text "Subscription"
    click_button "Activate HYC Managed Service"
    assert_text "HYC Managed Service activated."
    assert_button "Revoke HYC Managed Service"
    click_button "Revoke HYC Managed Service"
    assert_text "HYC Managed Service revoked."
    assert_button "Activate HYC Managed Service"
  end

  test "Managed Owner sees document actions only for their own verified document" do
    account = create_account(name: "Document Controls Account")
    owner = create_user(email: "controls-owner@example.test", role: "owner")
    admin = create_user(email: "controls-admin@example.test", role: "admin")
    create_account_membership(user: owner, account:, access_level: "editor")
    ManagedServiceRelationship::Transition.call!(account:, active: true, actor: admin)
    own = Document.create!(account:, created_by_user: owner, title: "My document", document_type: "other")
    professional = Document.create!(account:, created_by_user: admin, title: "Professional document", document_type: "other")
    historical = Document.create!(account:, title: "Historical document", document_type: "other")
    sign_in_with_browser(owner)
    [ professional, historical ].each do |document|
      visit document_path(document)
      assert_text document.title
      assert_no_link "Edit / Add file"
      assert_no_button "Delete"
    end
    visit document_path(own)
    click_link "Edit / Add file", match: :first
    fill_in "Title", with: "My updated document"
    click_button "Save document"
    assert_text "My updated document"
    assert_button "Delete"
  end
end
