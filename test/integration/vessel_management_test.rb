require "test_helper"

class VesselManagementTest < ActionDispatch::IntegrationTest
  test "captain creates and searches for a vessel using slug URL" do
    sign_in_as
    account = create_account(name: "Elliott Family")

    assert_difference -> { Asset.vessels.count }, 1 do
      post vessels_path, params: {
        asset: {
          account_id: account.id,
          name: "North Star",
          make: "Ranger Tugs",
          model: "R-31",
          year: 2022,
          length: 31,
          registration_number: "NS-3100",
          marina: "Port Orchard Marina",
          slip: "B-12",
          notes: "Monitor battery voltage."
        }
      }
    end

    vessel = Asset.find_by!(name: "North Star")
    assert_redirected_to vessel_path(vessel)
    assert_equal "/vessels/north-star", vessel_path(vessel)
    assert_not vessel.primary_photo.attached?

    get vessels_path(q: "Port Orchard")
    assert_response :success
    assert_includes response.body, "North Star"

    get vessels_path(q: "Orchard")
    assert_response :success
    assert_includes response.body, "North Star"
  end

  test "captain updates active status and deletes a vessel" do
    sign_in_as
    vessel = create_vessel

    patch vessel_path(vessel), params: { asset: { name: "Blue Meridian II", account_id: vessel.account_id, active: "0" } }
    assert_redirected_to vessel_path(vessel.reload)
    assert_equal "blue-meridian-ii", vessel.slug
    assert_not vessel.active?

    get vessels_path
    assert_response :success
    assert_not_includes response.body, "Blue Meridian II"

    get vessels_path(include_inactive: "1")
    assert_response :success
    assert_includes response.body, "Blue Meridian II"

    assert_difference -> { Asset.vessels.count }, -1 do
      delete vessel_path(vessel)
    end
    assert_redirected_to vessels_path
  end

  test "internal user can reassign a vessel account" do
    sign_in_as
    source_account = create_account(name: "Elliott Family")
    target_account = create_account(name: "Harbor North")
    vessel = create_vessel(account: source_account, name: "Transferable Vessel")

    patch vessel_path(vessel), params: {
      asset: {
        name: vessel.name,
        account_id: target_account.id
      }
    }

    assert_redirected_to vessel_path(vessel.reload)
    assert_equal target_account, vessel.account
  end

  test "internal users create vessels with valid primary photos" do
    %w[captain admin].each do |role|
      sign_in_as create_user(email: "#{role}-create-photo@example.test", role: role)
      account = create_account(name: "Photo Owner #{role.titleize}")

      assert_difference -> { Asset.vessels.count }, 1 do
        assert_difference -> { ActiveStorage::Attachment.count }, 1 do
          post vessels_path, params: {
            asset: {
              account_id: account.id,
              name: "New Photo #{role.titleize}",
              make: "Sabre",
              primary_photo: fixture_file_upload("sample.jpg", "image/jpeg")
            }
          }
        end
      end

      vessel = Asset.find_by!(name: "New Photo #{role.titleize}")
      assert_redirected_to vessel_path(vessel)
      assert vessel.primary_photo.attached?
      assert_equal "image/jpeg", vessel.primary_photo.blob.content_type
    end
  end

  test "valid primary photo with inaccurate declared type is detected and accepted" do
    sign_in_as
    account = create_account(name: "Detected Photo Owner")

    assert_difference -> { Asset.vessels.count }, 1 do
      post vessels_path, params: {
        asset: {
          account_id: account.id,
          name: "Detected Photo",
          primary_photo: fixture_file_upload("sample.png", "text/plain")
        }
      }
    end

    vessel = Asset.find_by!(name: "Detected Photo")
    assert_redirected_to vessel_path(vessel)
    assert vessel.primary_photo.attached?
    assert_equal "image/png", vessel.primary_photo.blob.content_type
  end

  test "internal users upload valid vessel primary photos" do
    %w[captain admin].each do |role|
      sign_in_as create_user(email: "#{role}-photo@example.test", role: role)
      vessel = create_vessel(name: "Photo #{role.titleize}")

      patch vessel_path(vessel), params: {
        asset: {
          primary_photo: fixture_file_upload("sample.jpg", "image/jpeg")
        }
      }

      assert_redirected_to vessel_path(vessel)
      vessel.reload
      assert vessel.primary_photo.attached?
      assert_equal "image/jpeg", vessel.primary_photo.blob.content_type
    end
  end

  test "vessel new and edit forms expose image primary photo upload" do
    sign_in_as
    vessel = create_vessel

    get new_vessel_path

    assert_response :success
    assert_select "label[for=?]", "asset_primary_photo", "Primary vessel photo"
    assert_select "input[type=file][name=?][accept=?]", "asset[primary_photo]", Asset::PRIMARY_PHOTO_CONTENT_TYPES.join(",")
    assert_includes response.body, "Upload a JPEG, PNG, or WEBP image up to 10 MB."

    get edit_vessel_path(vessel)

    assert_response :success
    assert_select "input[type=file][name=?][accept=?]", "asset[primary_photo]", Asset::PRIMARY_PHOTO_CONTENT_TYPES.join(",")
    assert_includes response.body, "Upload a JPEG, PNG, or WEBP image up to 10 MB."
    assert_select "form[action=?]", primary_photo_vessel_path(vessel), count: 0
  end

  test "vessel edit form exposes remove button that submits delete when primary photo exists" do
    sign_in_as
    vessel = create_vessel
    vessel.primary_photo.attach(fixture_file_upload("sample.jpg", "image/jpeg"))

    get edit_vessel_path(vessel)

    assert_response :success
    assert_select "a[href=?][data-turbo-method=?]", primary_photo_vessel_path(vessel), "delete", count: 0
    assert_select "form[action=?][method=?]", primary_photo_vessel_path(vessel), "post" do
      assert_select "input[name=?][value=?]", "_method", "delete"
      assert_select "button", text: /Remove photo/
    end
    assert_includes response.body, "Remove this vessel photo?"
  end

  test "non-image primary photo declared as jpeg during vessel creation is rejected" do
    sign_in_as
    account = create_account(name: "Invalid Photo Owner")

    assert_no_difference -> { Asset.vessels.count } do
      assert_no_difference -> { ActiveStorage::Blob.count } do
        assert_no_difference -> { ActiveStorage::Attachment.count } do
          post vessels_path, params: {
            asset: {
              account_id: account.id,
              name: "Invalid Photo",
              primary_photo: fixture_file_upload("sample.pdf", "image/jpeg")
            }
          }
        end
      end
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "Primary photo must be a JPEG, PNG, or WEBP image"
  end

  test "failed vessel creation with valid primary photo does not create active storage rows" do
    sign_in_as
    account = create_account(name: "Validation Failure Owner")

    assert_no_difference -> { Asset.vessels.count } do
      assert_no_difference -> { ActiveStorage::Blob.count } do
        assert_no_difference -> { ActiveStorage::Attachment.count } do
          post vessels_path, params: {
            asset: {
              account_id: account.id,
              name: "",
              primary_photo: fixture_file_upload("sample.jpg", "image/jpeg")
            }
          }
        end
      end
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "Name can&#39;t be blank"
  end

  test "oversized primary photo during vessel creation is rejected" do
    sign_in_as
    account = create_account(name: "Oversized Photo Owner")
    oversized_file = Tempfile.new([ "oversized-primary-photo-create", ".jpg" ])

    begin
      oversized_file.binmode
      oversized_file.truncate(Asset::PRIMARY_PHOTO_MAX_SIZE + 1)
      oversized_file.rewind

      assert_no_difference -> { Asset.vessels.count } do
        assert_no_difference -> { ActiveStorage::Blob.count } do
          assert_no_difference -> { ActiveStorage::Attachment.count } do
            post vessels_path, params: {
              asset: {
                account_id: account.id,
                name: "Oversized Photo",
                primary_photo: Rack::Test::UploadedFile.new(oversized_file.path, "image/jpeg", true)
              }
            }
          end
        end
      end
    ensure
      oversized_file.close!
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "Primary photo must be 10 MB or smaller"
  end

  test "invalid vessel primary photo file type is rejected" do
    sign_in_as
    vessel = create_vessel

    assert_no_difference -> { ActiveStorage::Blob.count } do
      assert_no_difference -> { ActiveStorage::Attachment.count } do
        patch vessel_path(vessel), params: {
          asset: {
            primary_photo: fixture_file_upload("sample.pdf", "application/pdf")
          }
        }
      end
    end

    assert_response :unprocessable_entity
    assert_not vessel.reload.primary_photo.attached?
    assert_includes response.body, "Primary photo must be a JPEG, PNG, or WEBP image"
  end

  test "spoofed primary photo replacement preserves existing photo and other attachments" do
    user = create_user(email: "captain-invalid-replacement@example.test")
    sign_in_as user
    vessel = create_vessel
    vessel.primary_photo.attach(fixture_file_upload("sample.jpg", "image/jpeg"))
    existing_blob_id = vessel.primary_photo.blob.id
    document = vessel.documents.create!(account: vessel.account, title: "Insurance", document_type: "insurance")
    document.file.attach(fixture_file_upload("sample.pdf", "application/pdf"))
    service_visit = vessel.service_visits.create!(performed_by_user: user, visit_date: Date.current, summary: "Dock check")
    service_visit.photos.attach(fixture_file_upload("sample.png", "image/png"))

    assert_no_difference -> { ActiveStorage::Blob.count } do
      assert_no_difference -> { ActiveStorage::Attachment.count } do
        patch vessel_path(vessel), params: {
          asset: {
            primary_photo: fixture_file_upload("sample.pdf", "image/jpeg")
          }
        }
      end
    end

    assert_response :unprocessable_entity
    vessel.reload
    assert vessel.primary_photo.attached?
    assert_equal existing_blob_id, vessel.primary_photo.blob.id
    assert document.reload.file.attached?
    assert service_visit.reload.photos.attached?
    assert_select "img[alt=?]", "#{vessel.name} primary photo"
    assert_includes response.body, "Primary photo must be a JPEG, PNG, or WEBP image"
  end

  test "oversized vessel primary photo is rejected" do
    sign_in_as
    vessel = create_vessel
    oversized_file = Tempfile.new([ "oversized-primary-photo", ".jpg" ])

    begin
      oversized_file.binmode
      oversized_file.truncate(Asset::PRIMARY_PHOTO_MAX_SIZE + 1)
      oversized_file.rewind

      assert_no_difference -> { ActiveStorage::Blob.count } do
        assert_no_difference -> { ActiveStorage::Attachment.count } do
          patch vessel_path(vessel), params: {
            asset: {
              primary_photo: Rack::Test::UploadedFile.new(oversized_file.path, "image/jpeg", true)
            }
          }
        end
      end
    ensure
      oversized_file.close!
    end

    assert_response :unprocessable_entity
    assert_not vessel.reload.primary_photo.attached?
    assert_includes response.body, "Primary photo must be 10 MB or smaller"
  end

  test "oversized primary photo replacement preserves existing photo" do
    sign_in_as
    vessel = create_vessel
    vessel.primary_photo.attach(fixture_file_upload("sample.jpg", "image/jpeg"))
    existing_blob_id = vessel.primary_photo.blob.id
    oversized_file = Tempfile.new([ "oversized-primary-photo-replacement", ".jpg" ])

    begin
      oversized_file.binmode
      oversized_file.truncate(Asset::PRIMARY_PHOTO_MAX_SIZE + 1)
      oversized_file.rewind

      assert_no_difference -> { ActiveStorage::Blob.count } do
        assert_no_difference -> { ActiveStorage::Attachment.count } do
          patch vessel_path(vessel), params: {
            asset: {
              primary_photo: Rack::Test::UploadedFile.new(oversized_file.path, "image/jpeg", true)
            }
          }
        end
      end
    ensure
      oversized_file.close!
    end

    assert_response :unprocessable_entity
    vessel.reload
    assert vessel.primary_photo.attached?
    assert_equal existing_blob_id, vessel.primary_photo.blob.id
    assert_includes response.body, "Primary photo must be 10 MB or smaller"
  end

  test "valid primary photo replacement replaces previous photo" do
    sign_in_as
    vessel = create_vessel
    vessel.primary_photo.attach(fixture_file_upload("sample.jpg", "image/jpeg"))
    previous_blob_id = vessel.primary_photo.blob.id

    patch vessel_path(vessel), params: {
      asset: {
        primary_photo: fixture_file_upload("sample.png", "image/png")
      }
    }

    assert_redirected_to vessel_path(vessel)
    vessel.reload
    assert vessel.primary_photo.attached?
    assert_not_equal previous_blob_id, vessel.primary_photo.blob.id
    assert_equal "image/png", vessel.primary_photo.blob.content_type
  end

  test "valid replacement is not attached when vessel update validation fails" do
    sign_in_as
    vessel = create_vessel(name: "Validation Photo")
    vessel.primary_photo.attach(fixture_file_upload("sample.jpg", "image/jpeg"))
    original_blob_id = vessel.primary_photo.blob.id

    assert_no_difference -> { ActiveStorage::Blob.count } do
      assert_no_difference -> { ActiveStorage::Attachment.count } do
        patch vessel_path(vessel), params: {
          asset: {
            name: "",
            primary_photo: fixture_file_upload("sample.png", "image/png")
          }
        }
      end
    end

    assert_response :unprocessable_entity
    vessel.reload
    assert_equal "Validation Photo", vessel.name
    assert vessel.primary_photo.attached?
    assert_equal original_blob_id, vessel.primary_photo.blob.id
    assert_includes response.body, "Name can&#39;t be blank"

    patch vessel_path(vessel), params: {
      asset: {
        name: "Validation Photo II",
        primary_photo: fixture_file_upload("sample.png", "image/png")
      }
    }

    vessel.reload
    assert_redirected_to vessel_path(vessel)
    assert_equal "Validation Photo II", vessel.name
    assert vessel.primary_photo.attached?
    assert_not_equal original_blob_id, vessel.primary_photo.blob.id
    assert_equal "image/png", vessel.primary_photo.blob.content_type
  end

  test "vessel update without a new primary photo still works" do
    sign_in_as
    vessel = create_vessel(name: "No Photo Update")
    vessel.primary_photo.attach(fixture_file_upload("sample.jpg", "image/jpeg"))
    original_blob_id = vessel.primary_photo.blob.id

    patch vessel_path(vessel), params: {
      asset: {
        name: "No Photo Update II",
        marina: "Shilshole Bay Marina"
      }
    }

    vessel.reload
    assert_redirected_to vessel_path(vessel)
    assert_equal "No Photo Update II", vessel.name
    assert_equal "Shilshole Bay Marina", vessel.marina
    assert_equal original_blob_id, vessel.primary_photo.blob.id
  end

  test "vessel show displays primary photo when attached" do
    sign_in_as
    vessel = create_vessel
    vessel.primary_photo.attach(fixture_file_upload("sample.jpg", "image/jpeg"))

    get vessel_path(vessel)

    assert_response :success
    assert_select "img[alt=?]", "#{vessel.name} primary photo"

    get root_path

    assert_response :success
    assert_select "img[alt=?]", "#{vessel.name} primary photo"
  end

  test "vessel show and index display primary photo fallback" do
    sign_in_as
    vessel = create_vessel

    get vessel_path(vessel)

    assert_response :success
    assert_select "[aria-label=?]", "Primary photo placeholder for #{vessel.name}"

    get root_path

    assert_response :success
    assert_select "[aria-label=?]", "Primary photo placeholder for #{vessel.name}"

    get vessels_path

    assert_response :success
    assert_select "[aria-label=?]", "Primary photo placeholder for #{vessel.name}"
  end

  test "internal users remove vessel primary photos without affecting other attachments" do
    %w[captain admin].each do |role|
      user = create_user(email: "#{role}-remove-photo@example.test", role: role)
      sign_in_as user
      vessel = create_vessel(name: "Remove Photo #{role.titleize}")
      vessel.primary_photo.attach(fixture_file_upload("sample.jpg", "image/jpeg"))
      primary_photo_blob_id = vessel.primary_photo.blob.id
      document = vessel.documents.create!(account: vessel.account, title: "Insurance #{role}", document_type: "insurance")
      document.file.attach(fixture_file_upload("sample.pdf", "application/pdf"))
      service_visit = vessel.service_visits.create!(performed_by_user: user, visit_date: Date.current, summary: "Dock check")
      service_visit.photos.attach(fixture_file_upload("sample.png", "image/png"))

      assert_no_difference -> { Asset.count } do
        delete primary_photo_vessel_path(vessel)
      end

      assert_redirected_to vessel_path(vessel)
      follow_redirect!
      assert_includes response.body, "Primary vessel photo removed."
      assert_not vessel.reload.primary_photo.attached?
      assert_not ActiveStorage::Blob.exists?(primary_photo_blob_id)
      assert document.reload.file.attached?
      assert service_visit.reload.photos.attached?
      assert_select "[aria-label=?]", "Primary photo placeholder for #{vessel.name}"

      get root_path
      assert_response :success
      assert_select "[aria-label=?]", "Primary photo placeholder for #{vessel.name}"

      get vessels_path
      assert_response :success
      assert_select "[aria-label=?]", "Primary photo placeholder for #{vessel.name}"
    end
  end

  test "removing a missing vessel primary photo is graceful" do
    sign_in_as
    vessel = create_vessel

    assert_no_difference -> { ActiveStorage::Blob.count } do
      delete primary_photo_vessel_path(vessel)
    end

    assert_redirected_to vessel_path(vessel)
    follow_redirect!
    assert_includes response.body, "Primary vessel photo removed."
    assert_select "[aria-label=?]", "Primary photo placeholder for #{vessel.name}"
  end

  test "owner vessel list remains scoped when primary photos exist" do
    owner_account = create_account(name: "Elliott Family")
    other_account = create_account(name: "Harbor North")
    owner_vessel = create_vessel(account: owner_account, name: "Owner Vessel")
    other_vessel = create_vessel(account: other_account, name: "Restricted Vessel")
    owner_vessel.primary_photo.attach(fixture_file_upload("sample.jpg", "image/jpeg"))
    other_vessel.primary_photo.attach(fixture_file_upload("sample.png", "image/png"))
    owner = create_user(email: "owner-photo-scope@example.test", role: "owner")
    create_account_membership(user: owner, account: owner_account)
    sign_in_as owner

    get vessels_path

    assert_response :success
    assert_includes response.body, "Owner Vessel"
    assert_select "img[alt=?]", "Owner Vessel primary photo"
    assert_not_includes response.body, "Restricted Vessel"
    assert_select "img[alt=?]", "Restricted Vessel primary photo", count: 0
  end

  test "owner cannot update another account vessel primary photo" do
    owner_account = create_account(name: "Elliott Family")
    other_account = create_account(name: "Harbor North")
    other_vessel = create_vessel(account: other_account, name: "Restricted Vessel")
    owner = create_user(email: "owner-photo-update@example.test", role: "owner")
    create_account_membership(user: owner, account: owner_account)
    sign_in_as owner

    patch vessel_path(other_vessel), params: {
      asset: {
        primary_photo: fixture_file_upload("sample.jpg", "image/jpeg")
      }
    }

    assert_response :not_found
    assert_not other_vessel.reload.primary_photo.attached?
  end

  test "owner cannot remove another account vessel primary photo" do
    owner_account = create_account(name: "Elliott Family")
    other_account = create_account(name: "Harbor North")
    other_vessel = create_vessel(account: other_account, name: "Restricted Vessel")
    other_vessel.primary_photo.attach(fixture_file_upload("sample.jpg", "image/jpeg"))
    primary_photo_blob_id = other_vessel.primary_photo.blob.id
    owner = create_user(email: "owner-photo-remove@example.test", role: "owner")
    create_account_membership(user: owner, account: owner_account)
    sign_in_as owner

    delete primary_photo_vessel_path(other_vessel)

    assert_response :not_found
    assert other_vessel.reload.primary_photo.attached?
    assert ActiveStorage::Blob.exists?(primary_photo_blob_id)
  end

  test "owner role cannot reassign a vessel account" do
    vessel = create_vessel
    other_account = create_account(name: "Other Owner")
    sign_in_as create_user(email: "owner@example.test", role: "owner")

    patch vessel_path(vessel), params: { asset: { name: vessel.name, account_id: other_account.id } }

    assert_response :not_found
    assert_equal vessel.account, vessel.reload.account
  end

  test "captain deletes a due-dated note" do
    sign_in_as
    vessel = create_vessel
    note = vessel.binder_notes.create!(account: vessel.account, title: "Line chafe", body: "Replace spring line.", note_type: "issue", due_date: Date.tomorrow)

    assert_difference -> { BinderNote.count }, -1 do
      delete vessel_binder_note_path(vessel, note)
    end
    assert_redirected_to vessel_path(vessel, anchor: "notes")
  end

  test "captain edits a note" do
    sign_in_as
    vessel = create_vessel
    note = vessel.binder_notes.create!(account: vessel.account, title: "Line chafe", body: "Replace spring line.", note_type: "issue")

    patch vessel_binder_note_path(vessel, note), params: {
      binder_note: {
        title: "Replace spring line",
        body: "Line is chafed at the cleat.",
        note_type: "maintenance",
        due_date: Date.tomorrow
      }
    }

    assert_redirected_to vessel_path(vessel, anchor: "notes")
    note.reload
    assert_equal "Replace spring line", note.title
    assert_equal "maintenance", note.note_type
    assert_equal Date.tomorrow, note.due_date
  end
end
