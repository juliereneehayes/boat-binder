require "test_helper"

class OwnerEditorAccessTest < ActionDispatch::IntegrationTest
  setup do
    @account = create_account(name: "Elliott Family")
    @other_account = create_account(name: "Harbor North")
    @read_only_account = create_account(name: "Read Only Harbor")
    qualify_self_managed_subscription(@account)
    qualify_self_managed_subscription(@read_only_account)
    @vessel = create_vessel(account: @account, name: "Blue Meridian")
    @other_vessel = create_vessel(account: @other_account, name: "Tide Runner")
    @read_only_vessel = create_vessel(account: @read_only_account, name: "Quiet Harbor")

    @editor_owner = create_user(email: "editor-owner@example.test", role: "owner", name: "Editor Owner")
    create_account_membership(user: @editor_owner, account: @account, access_level: "editor")

    @read_only_owner = create_user(email: "readonly-owner@example.test", role: "owner", name: "Read Only Owner")
    create_account_membership(user: @read_only_owner, account: @read_only_account, access_level: "read_only")
  end

  test "internal users retain write access" do
    @account.subscription.update!(Subscription.default_local_attributes)
    captain = create_user(email: "captain-editor-access@example.test", role: "captain")
    sign_in_as captain

    get new_vessel_path
    assert_response :success

    assert_difference -> { Asset.vessels.count }, 1 do
      post vessels_path, params: {
        asset: {
          account_id: @account.id,
          name: "Captain Created",
          make: "Ranger",
          model: "R-31"
        }
      }
    end
    assert_redirected_to vessel_path(Asset.find_by!(name: "Captain Created"))

    patch vessel_path(@vessel), params: {
      asset: { name: "Blue Meridian II", account_id: @account.id }
    }

    assert_redirected_to vessel_path(@vessel.reload)
    assert_equal "Blue Meridian II", @vessel.name
  end

  test "active self managed editor owner creates a vessel in the server resolved account" do
    sign_in_as @editor_owner

    get new_vessel_path
    assert_response :success
    assert_includes response.body, @account.name
    assert_select "select[name='asset[account_id]']", count: 0

    assert_difference -> { @account.assets.vessels.count }, 1 do
      post vessels_path, params: {
        asset: {
          name: "Owner Created Vessel"
        }
      }
    end

    vessel = Asset.find_by!(name: "Owner Created Vessel")
    assert_redirected_to vessel_path(vessel)
    assert_equal @account, vessel.account
  end

  test "trialing self managed editor owner creates a vessel" do
    qualify_self_managed_subscription(@account, status: "trialing")
    sign_in_as @editor_owner

    assert_difference -> { @account.assets.vessels.count }, 1 do
      post vessels_path, params: {
        asset: { name: "Trial Vessel" }
      }
    end

    vessel = Asset.find_by!(name: "Trial Vessel")
    assert_redirected_to vessel_path(vessel)
    assert_equal @account, vessel.account
  end

  test "editor owner cannot choose another account while creating a vessel" do
    sign_in_as @editor_owner

    assert_no_difference -> { Asset.vessels.count } do
      post vessels_path, params: {
        asset: {
          account_id: @other_account.id,
          name: "Cross Account Vessel"
        }
      }
    end

    assert_access_denied_redirect
  end

  test "editor owner with multiple manageable accounts cannot use unscoped vessel creation" do
    qualify_self_managed_subscription(@other_account)
    create_account_membership(user: @editor_owner, account: @other_account, access_level: "editor")
    sign_in_as @editor_owner

    get new_vessel_path
    assert_access_denied_redirect

    assert_no_difference -> { Asset.vessels.count } do
      post vessels_path, params: {
        asset: { account_id: @account.id, name: "Ambiguous Account Vessel" }
      }
    end
    assert_access_denied_redirect
  end

  test "read only owner cannot access vessel creation" do
    sign_in_as @read_only_owner

    get new_vessel_path
    assert_access_denied_redirect

    assert_no_difference -> { Asset.vessels.count } do
      post vessels_path, params: {
        asset: {
          account_id: @account.id,
          name: "Read Only Created Vessel"
        }
      }
    end
    assert_access_denied_redirect

    get new_vessel_service_visit_path(@read_only_vessel)
    assert_access_denied_redirect

    assert_no_difference -> { ServiceVisit.count } do
      post vessel_service_visits_path(@read_only_vessel), params: {
        service_visit: { visit_date: Date.current, summary: "Read only visit" }
      }
    end
    assert_access_denied_redirect
  end

  test "editor owner can create and edit a note in their account" do
    sign_in_as @editor_owner

    assert_difference -> { @vessel.binder_notes.count }, 1 do
      post vessel_binder_notes_path(@vessel), params: {
        binder_note: {
          title: "Owner preference",
          body: "Use the north gate after hours.",
          note_type: "owner_preference",
          due_date: Date.tomorrow
        }
      }
    end

    note = @vessel.binder_notes.order(:created_at).last
    assert_redirected_to vessel_path(@vessel, anchor: "notes")

    patch vessel_binder_note_path(@vessel, note), params: {
      binder_note: {
        title: "Updated owner preference",
        body: note.body,
        note_type: note.note_type,
        due_date: note.due_date
      }
    }

    assert_redirected_to vessel_path(@vessel, anchor: "notes")
    assert_equal "Updated owner preference", note.reload.title

    assert_difference -> { @vessel.binder_notes.count }, -1 do
      delete vessel_binder_note_path(@vessel, note)
    end

    assert_redirected_to vessel_path(@vessel, anchor: "notes")
  end

  test "read only owner cannot create or edit a note" do
    note = @read_only_vessel.binder_notes.create!(
      account: @read_only_account,
      title: "Existing note",
      body: "Original body",
      note_type: "general"
    )
    sign_in_as @read_only_owner

    assert_no_difference -> { @read_only_vessel.binder_notes.count } do
      post vessel_binder_notes_path(@read_only_vessel), params: {
        binder_note: { title: "Blocked note", body: "Nope", note_type: "general" }
      }
    end
    assert_access_denied_redirect

    patch vessel_binder_note_path(@read_only_vessel, note), params: {
      binder_note: { title: "Blocked edit", body: note.body, note_type: note.note_type }
    }
    assert_access_denied_redirect
    assert_equal "Existing note", note.reload.title
  end

  test "editor owner can create and update a reminder in their account" do
    sign_in_as @editor_owner

    assert_difference -> { @vessel.reminders.count }, 1 do
      post reminders_path, params: {
        reminder: {
          asset_id: @vessel.id,
          title: "Renew registration",
          due_date: Date.tomorrow,
          reminder_type: "registration"
        }
      }
    end

    reminder = @vessel.reminders.order(:created_at).last
    assert_redirected_to reminders_path

    patch reminder_path(reminder), params: {
      reminder: {
        asset_id: @vessel.id,
        title: "Renew tabs",
        due_date: Date.tomorrow + 1.day,
        reminder_type: "registration",
        status: "pending"
      }
    }

    assert_redirected_to reminders_path
    assert_equal "Renew tabs", reminder.reload.title

    patch reminder_path(reminder, status_action: "complete"), params: {
      reminder: { asset_id: @vessel.id }
    }

    assert_redirected_to reminders_path
    assert_equal "completed", reminder.reload.status
  end

  test "editor owner creates and edits a service visit in their account" do
    battery = create_battery(asset: @vessel, name: "House Battery")
    sign_in_as @editor_owner

    get new_vessel_service_visit_path(@vessel)

    assert_response :success
    assert_includes response.body, "Recorded by"
    assert_includes response.body, battery.name

    assert_difference -> { @vessel.service_visits.count }, 1 do
      post vessel_service_visits_path(@vessel), params: {
        service_visit: {
          visit_date: Date.current,
          summary: "Owner completed the dock check.",
          condition_notes: "All systems normal."
        }
      }
    end

    visit = @vessel.service_visits.find_by!(summary: "Owner completed the dock check.")
    assert_redirected_to vessel_service_visit_path(@vessel, visit)
    assert_equal @editor_owner, visit.performed_by_user
    visit.photos.attach(fixture_file_upload("sample.jpg", "image/jpeg"))

    get vessel_service_visit_path(@vessel, visit)
    assert_response :success
    assert_select "a[href=?]", edit_vessel_service_visit_path(@vessel, visit), text: "Edit Visit"

    get edit_vessel_service_visit_path(@vessel, visit)

    assert_response :success
    assert_select "form[action=?]", vessel_service_visit_path(@vessel, visit)
    assert_select "input[name=issue_title]", count: 0

    patch vessel_service_visit_path(@vessel, visit), params: {
      service_visit: {
        visit_date: Date.current,
        summary: "Owner updated the dock check.",
        condition_notes: "Battery reading added.",
        photos: [ fixture_file_upload("sample.png", "image/png") ]
      }
    }

    assert_redirected_to vessel_service_visit_path(@vessel, visit)
    assert_equal "Owner updated the dock check.", visit.reload.summary
    assert_equal @editor_owner, visit.performed_by_user
    assert_equal [ "image/jpeg", "image/png" ], visit.photos.map { |photo| photo.blob.content_type }.sort
  end

  test "editor owner cannot create or edit service visits outside their account" do
    restricted_visit = @other_vessel.service_visits.create!(
      performed_by_user: create_user(email: "visit-author@example.test"),
      visit_date: Date.current,
      summary: "Restricted visit"
    )
    sign_in_as @editor_owner

    get new_vessel_service_visit_path(@other_vessel)
    assert_response :not_found

    assert_no_difference -> { ServiceVisit.count } do
      post vessel_service_visits_path(@other_vessel), params: {
        service_visit: { visit_date: Date.current, summary: "Unauthorized visit" }
      }
    end
    assert_response :not_found

    patch vessel_service_visit_path(@other_vessel, restricted_visit), params: {
      service_visit: { visit_date: Date.current, summary: "Unauthorized update" }
    }
    assert_response :not_found
    assert_equal "Restricted visit", restricted_visit.reload.summary
  end

  test "editor owner creates and edits vessel battery configuration without delete access" do
    sign_in_as @editor_owner

    assert_difference -> { @vessel.asset_batteries.count }, 1 do
      post vessel_batteries_path(@vessel), params: {
        asset_battery: {
          name: "Owner House Battery",
          location: "Aft lazarette",
          battery_type: "AGM",
          active: "1"
        }
      }
    end

    battery = @vessel.asset_batteries.find_by!(name: "Owner House Battery")
    assert_redirected_to vessel_path(@vessel, anchor: "batteries")

    patch vessel_battery_path(@vessel, battery), params: {
      asset_battery: {
        name: "Owner House Bank",
        location: "Aft lazarette",
        battery_type: "Lithium",
        active: "1"
      }
    }

    assert_redirected_to vessel_path(@vessel, anchor: "batteries")
    assert_equal "Owner House Bank", battery.reload.name

    assert_no_difference -> { AssetBattery.count } do
      delete vessel_battery_path(@vessel, battery)
    end
    assert_access_denied_redirect

    get new_vessel_battery_path(@other_vessel)
    assert_response :not_found

    assert_no_difference -> { AssetBattery.count } do
      post vessel_batteries_path(@other_vessel), params: {
        asset_battery: { name: "Unauthorized Battery", active: "1" }
      }
    end
    assert_response :not_found
  end

  test "editor owner can edit permitted vessel fields" do
    sign_in_as @editor_owner

    get vessel_path(@vessel)
    assert_response :success
    assert_includes response.body, @vessel.name

    get edit_vessel_path(@vessel)
    assert_response :success
    assert_select "form[action=?]", vessel_path(@vessel)

    patch vessel_path(@vessel), params: {
      asset: {
        account_id: @account.id,
        name: "Blue Meridian Updated",
        marina: "Elliott Bay Marina",
        slip: "B-12"
      }
    }

    assert_redirected_to vessel_path(@vessel.reload)
    assert_equal "Blue Meridian Updated", @vessel.name
    assert_equal "Elliott Bay Marina", @vessel.marina
    assert_equal "B-12", @vessel.slip
  end

  test "editor owner cannot load or edit vessels outside active accounts" do
    sign_in_as @editor_owner

    get vessel_path(@other_vessel)
    assert_response :not_found

    get edit_vessel_path(@other_vessel)
    assert_response :not_found

    patch vessel_path(@other_vessel), params: {
      asset: {
        name: "Unauthorized update"
      }
    }

    assert_response :not_found
    assert_equal "Tide Runner", @other_vessel.reload.name
  end

  test "editor owner cannot reassign a vessel account with a crafted request" do
    sign_in_as @editor_owner

    patch vessel_path(@vessel), params: {
      asset: {
        account_id: @other_account.id,
        name: "Blue Meridian Renamed"
      }
    }

    assert_redirected_to vessel_path(@vessel.reload)
    assert_equal "Blue Meridian Renamed", @vessel.name
    assert_equal @account, @vessel.account
  end

  test "editor owner with two editor memberships still cannot transfer vessels" do
    create_account_membership(user: @editor_owner, account: @other_account, access_level: "editor")
    sign_in_as @editor_owner

    patch vessel_path(@vessel), params: {
      asset: {
        account_id: @other_account.id,
        name: "Blue Meridian Dual Editor"
      }
    }

    assert_redirected_to vessel_path(@vessel.reload)
    assert_equal "Blue Meridian Dual Editor", @vessel.name
    assert_equal @account, @vessel.account
  end

  test "editor owner cannot delete a vessel" do
    sign_in_as @editor_owner

    vessel_lookup_queries = count_sql_queries(->(sql) {
      sql.include?("FROM \"assets\"")
    }) do
      delete vessel_path(@vessel)
    end

    assert_equal 0, vessel_lookup_queries
    assert_access_denied_redirect
    assert Asset.exists?(@vessel.id)
  end

  test "editor owner can upload and replace a vessel primary photo" do
    sign_in_as @editor_owner

    patch vessel_path(@vessel), params: {
      asset: {
        account_id: @account.id,
        name: @vessel.name,
        primary_photo: fixture_file_upload("sample.jpg", "image/jpeg")
      }
    }

    assert_redirected_to vessel_path(@vessel.reload)
    assert @vessel.primary_photo.attached?
    first_blob_id = @vessel.primary_photo.blob.id

    patch vessel_path(@vessel), params: {
      asset: {
        account_id: @account.id,
        name: @vessel.name,
        primary_photo: fixture_file_upload("sample.png", "image/png")
      }
    }

    assert_redirected_to vessel_path(@vessel.reload)
    assert @vessel.primary_photo.attached?
    assert_not_equal first_blob_id, @vessel.primary_photo.blob.id
    assert_equal "image/png", @vessel.primary_photo.blob.content_type
    assert_equal @account, @vessel.account
  end

  test "editor owner can remove a vessel primary photo without changing account" do
    @vessel.primary_photo.attach(fixture_file_upload("sample.jpg", "image/jpeg"))
    sign_in_as @editor_owner

    delete primary_photo_vessel_path(@vessel)

    assert_redirected_to vessel_path(@vessel)
    assert_not @vessel.reload.primary_photo.attached?
    assert_equal @account, @vessel.account
  end

  test "editor owner can create a document with a supported file" do
    sign_in_as @editor_owner

    assert_difference -> { @vessel.documents.count }, 1 do
      post vessel_documents_path(@vessel), params: {
        document: {
          title: "Insurance binder",
          document_type: "insurance",
          notes: "Uploaded by owner.",
          file: fixture_file_upload("sample.pdf", "application/pdf")
        }
      }
    end

    document = @vessel.documents.order(:created_at).last
    assert_redirected_to vessel_path(@vessel, anchor: "documents")
    assert document.file.attached?
    assert_equal "application/pdf", document.file.blob.content_type

    assert_difference -> { @vessel.documents.count }, -1 do
      delete vessel_document_path(@vessel, document)
    end

    assert_redirected_to vessel_path(@vessel, anchor: "documents")
  end

  test "editor owner creates an account level document only in their manageable account" do
    sign_in_as @editor_owner

    get new_document_path

    assert_response :success
    assert_select "select[name='document[account_id]']", count: 0
    assert_select "p", text: @account.name
    assert_select "select[name='document[asset_id]'] option[value=?]", @vessel.id.to_s
    assert_select "select[name='document[asset_id]'] option[value=?]", @other_vessel.id.to_s, count: 0

    assert_difference -> { @account.documents.count }, 1 do
      post documents_path, params: {
        document: {
          title: "Owner insurance policy",
          document_type: "insurance",
          file: fixture_file_upload("sample.pdf", "application/pdf")
        }
      }
    end

    document = @account.documents.find_by!(title: "Owner insurance policy")
    assert_redirected_to documents_path
    assert_nil document.asset
    assert document.file.attached?
  end

  test "editor owner can associate a global document only with a vessel in the resolved account" do
    sign_in_as @editor_owner

    assert_difference -> { @vessel.documents.count }, 1 do
      post documents_path, params: {
        document: {
          asset_id: @vessel.id,
          title: "Owner vessel policy",
          document_type: "insurance",
          file: fixture_file_upload("sample.pdf", "application/pdf")
        }
      }
    end

    document = @vessel.documents.find_by!(title: "Owner vessel policy")
    assert_equal @account, document.account
    assert_equal @vessel, document.asset
    assert_redirected_to vessel_path(@vessel, anchor: "documents")
  end

  test "editor owner cannot forge account or vessel while uploading a document" do
    sign_in_as @editor_owner

    assert_no_difference -> { Document.count } do
      post documents_path, params: {
        document: {
          account_id: @other_account.id,
          title: "Forged owner document",
          document_type: "insurance",
          file: fixture_file_upload("sample.pdf", "application/pdf")
        }
      }
    end
    assert_access_denied_redirect

    assert_no_difference -> { Document.count } do
      post documents_path, params: {
        document: {
          asset_id: @other_vessel.id,
          title: "Forged vessel document",
          document_type: "insurance",
          file: fixture_file_upload("sample.pdf", "application/pdf")
        }
      }
    end
    assert_response :not_found
  end

  test "editor owner with multiple manageable accounts cannot use unscoped document upload" do
    qualify_self_managed_subscription(@other_account)
    create_account_membership(user: @editor_owner, account: @other_account, access_level: "editor")
    sign_in_as @editor_owner

    get new_document_path
    assert_access_denied_redirect

    assert_no_difference -> { Document.count } do
      post documents_path, params: {
        document: {
          title: "Ambiguous document",
          document_type: "insurance",
          file: fixture_file_upload("sample.pdf", "application/pdf")
        }
      }
    end
    assert_access_denied_redirect
  end

  test "editor owner completes and reopens follow up while read only and cross account access fail closed" do
    visit = @vessel.service_visits.create!(
      performed_by_user: @editor_owner,
      visit_date: Date.current,
      follow_up_needed: true,
      follow_up_notes: "Replace dock line."
    )
    restricted_visit = @other_vessel.service_visits.create!(
      performed_by_user: create_user(email: "restricted-follow-up-author@example.test"),
      visit_date: Date.current,
      follow_up_needed: true
    )
    read_only_visit = @read_only_vessel.service_visits.create!(
      performed_by_user: create_user(email: "read-only-follow-up-author@example.test"),
      visit_date: Date.current,
      follow_up_needed: true
    )

    sign_in_as @editor_owner
    patch complete_follow_up_vessel_service_visit_path(@vessel, visit)
    assert_redirected_to vessel_service_visit_path(@vessel, visit)
    assert_equal @editor_owner, visit.reload.follow_up_completed_by_user

    patch reopen_follow_up_vessel_service_visit_path(@vessel, visit)
    assert_redirected_to vessel_service_visit_path(@vessel, visit)
    assert visit.reload.follow_up_open?

    patch complete_follow_up_vessel_service_visit_path(@other_vessel, restricted_visit)
    assert_response :not_found
    assert restricted_visit.reload.follow_up_open?

    sign_in_as @read_only_owner
    patch complete_follow_up_vessel_service_visit_path(@read_only_vessel, read_only_visit)
    assert_access_denied_redirect
    assert read_only_visit.reload.follow_up_open?
  end

  test "editor membership for one account does not allow modifying a read only account" do
    qualify_self_managed_subscription(@other_account)
    create_account_membership(user: @editor_owner, account: @other_account, access_level: "read_only")
    sign_in_as @editor_owner

    patch vessel_path(@other_vessel), params: {
      asset: {
        account_id: @other_account.id,
        name: "Unauthorized update"
      }
    }

    assert_access_denied_redirect
    assert_equal "Tide Runner", @other_vessel.reload.name
  end

  test "inactive editor membership does not grant write access" do
    inactive_owner = create_user(email: "inactive-editor-owner@example.test", role: "owner")
    create_account_membership(user: inactive_owner, account: @account, access_level: "editor", active: false)
    sign_in_as inactive_owner

    assert_no_difference -> { @vessel.binder_notes.count } do
      post vessel_binder_notes_path(@vessel), params: {
        binder_note: { title: "Inactive edit", body: "Blocked", note_type: "general" }
      }
    end

    assert_access_denied_redirect
  end

  test "editor owner sees account write controls while read only owner does not" do
    note = @vessel.binder_notes.create!(
      account: @account,
      title: "Visible note",
      body: "Original",
      note_type: "general"
    )
    read_only_note = @read_only_vessel.binder_notes.create!(
      account: @read_only_account,
      title: "Read only visible note",
      body: "Original",
      note_type: "general"
    )

    sign_in_as @editor_owner
    get vessel_path(@vessel)

    assert_response :success
    assert_select "a[href=?]", edit_vessel_path(@vessel), text: "Edit"
    assert_select "a[href=?]", new_vessel_document_path(@vessel), text: "Upload"
    assert_select "form[action=?]", vessel_binder_notes_path(@vessel)
    assert_select "a[href=?]", edit_vessel_binder_note_path(@vessel, note), text: "Edit"
    assert_select "a[href=?]", new_vessel_service_visit_path(@vessel)
    assert_select "a[href=?]", new_vessel_battery_path(@vessel)

    get vessels_path
    assert_response :success
    assert_select "a[href=?]", new_vessel_path

    get root_path
    assert_response :success
    assert_select "a[href=?]", new_vessel_path

    sign_in_as @read_only_owner
    get vessel_path(@read_only_vessel)

    assert_response :success
    assert_select "a[href=?]", edit_vessel_path(@read_only_vessel), text: "Edit", count: 0
    assert_select "a[href=?]", new_vessel_document_path(@read_only_vessel), count: 0
    assert_select "form[action=?]", vessel_binder_notes_path(@read_only_vessel), count: 0
    assert_select "a[href=?]", edit_vessel_binder_note_path(@read_only_vessel, read_only_note), count: 0
    assert_select "a[href=?]", new_vessel_service_visit_path(@read_only_vessel), count: 0
    assert_select "a[href=?]", new_vessel_battery_path(@read_only_vessel), count: 0
  end

  test "vessel form shows editable account selector only to internal users" do
    sign_in_as

    get edit_vessel_path(@vessel)

    assert_response :success
    assert_select "select[name='asset[account_id]']"
    assert_select "a[href=?]", new_owner_path, text: "Add owner"

    sign_in_as @editor_owner

    get edit_vessel_path(@vessel)

    assert_response :success
    assert_select "select[name='asset[account_id]']", count: 0
    assert_select "a[href=?]", new_owner_path, text: "Add owner", count: 0
    assert_includes response.body, @account.name
  end

  test "editor owner validation error rerender keeps owner account read only" do
    sign_in_as @editor_owner

    patch vessel_path(@vessel), params: {
      asset: {
        account_id: @other_account.id,
        name: "",
        marina: "Elliott Bay Marina"
      }
    }

    assert_response :unprocessable_entity
    assert_select "select[name='asset[account_id]']", count: 0
    assert_select "a[href=?]", new_owner_path, text: "Add owner", count: 0
    assert_includes response.body, @account.name
    assert_equal @account, @vessel.reload.account
  end

  test "repeated account write checks load editor membership ids once" do
    @vessel.documents.create!(account: @account, title: "Registration", document_type: "registration")
    @vessel.binder_notes.create!(account: @account, title: "Visible note", body: "Original", note_type: "general")
    sign_in_as @editor_owner

    editor_membership_queries = count_sql_queries(->(sql) {
      sql.include?("account_memberships") && sql.include?("access_level")
    }) do
      get vessel_path(@vessel)
    end

    assert_response :success
    assert_equal 1, editor_membership_queries
  end

  private

  def count_sql_queries(matcher)
    count = 0
    callback = lambda do |_name, _started, _finished, _unique_id, payload|
      sql = payload[:sql].to_s
      next if payload[:name] == "SCHEMA" || payload[:cached]

      count += 1 if matcher.call(sql)
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      yield
    end

    count
  end
end
