require "test_helper"

class OwnerWriteEntitlementTest < ActionDispatch::IntegrationTest
  setup do
    @now = Time.zone.local(2026, 8, 21, 12, 0, 0)
    @account = create_account(name: "Entitlement Owner")
    @vessel = create_vessel(account: @account, name: "Entitlement Vessel")
    @owner = create_user(email: "entitled-owner@example.test", role: "owner")
    create_account_membership(user: @owner, account: @account, access_level: "editor")
  end

  test "verified active trialing and canceling entitlements permit owner writes" do
    sign_in_as @owner

    qualifying_configurations = [
      { status: "active", current_period_ends_at: @now + 1.month },
      { status: "trialing", trial_ends_at: @now + 7.days },
      {
        status: "active",
        current_period_ends_at: @now + 1.month,
        cancel_at_period_end: true
      }
    ]

    travel_to @now do
      qualifying_configurations.each_with_index do |attributes, index|
        configure_verified_subscription(**attributes)
        new_name = "Qualifying Vessel #{index}"

        without_stripe_subscription_retrieval do
          patch vessel_path(@vessel), params: { asset: { name: new_name } }
        end

        assert_redirected_to vessel_path(@vessel.reload)
        assert_equal new_name, @vessel.name
      end
    end
  end

  test "non qualifying subscription states deny owner vessel writes" do
    sign_in_as @owner

    configurations = {
      "local legacy" => ->(subscription) {
        subscription.update!(
          provider: Subscription::LOCAL_PROVIDER,
          plan: "legacy",
          status: "active"
        )
      },
      "wrong provider" => ->(subscription) { subscription.update!(provider: Subscription::LOCAL_PROVIDER) },
      "wrong plan" => ->(subscription) { subscription.update!(plan: "professional") },
      "missing customer identifier" => ->(subscription) { subscription.update!(external_customer_id: nil) },
      "missing subscription identifier" => ->(subscription) { subscription.update!(external_subscription_id: nil) },
      "missing synchronization time" => ->(subscription) { subscription.update!(last_synced_at: nil) },
      "missing entitlement end" => ->(subscription) { subscription.update!(current_period_ends_at: nil) },
      "expired active period" => ->(subscription) { subscription.update!(current_period_ends_at: @now - 1.second) },
      "expired trial" => ->(subscription) {
        subscription.update!(status: "trialing", trial_ends_at: @now - 1.second)
      }
    }

    Subscription::STATUSES.excluding("active", "trialing").each do |status|
      configurations[status] = ->(subscription) { subscription.update!(status:) }
    end

    travel_to @now do
      configurations.each do |label, configure|
        subscription = configure_verified_subscription
        configure.call(subscription)

        assert_denied_vessel_update(label)
      end

      @account.subscription.destroy!
      assert_denied_vessel_update("missing subscription")
    end
  end

  test "trial and active entitlement boundaries deny owner writes at equality" do
    sign_in_as @owner

    travel_to @now do
      configure_verified_subscription(status: "active", current_period_ends_at: @now)
      assert_denied_vessel_update("active boundary")

      configure_verified_subscription(status: "trialing", trial_ends_at: @now)
      assert_denied_vessel_update("trial boundary")
    end
  end

  test "legacy owner direct mutations are denied without changing records or attachments" do
    document = @vessel.documents.create!(
      account: @account,
      title: "Existing registration",
      document_type: "registration"
    )
    document.file.attach(fixture_file_upload("sample.pdf", "application/pdf"))
    document_blob_id = document.file.blob.id
    @vessel.primary_photo.attach(fixture_file_upload("sample.jpg", "image/jpeg"))
    photo_blob_id = @vessel.primary_photo.blob.id
    reminder = @vessel.reminders.create!(
      title: "Existing reminder",
      due_date: Date.tomorrow,
      reminder_type: "maintenance",
      status: "pending"
    )
    completed_reminder = @vessel.reminders.create!(
      title: "Completed reminder",
      due_date: Date.yesterday,
      reminder_type: "maintenance",
      status: "completed",
      completed_at: Time.current
    )
    note = @vessel.binder_notes.create!(
      account: @account,
      title: "Existing note",
      body: "Original body",
      note_type: "general"
    )
    original_blob_count = ActiveStorage::Blob.count
    original_attachment_count = ActiveStorage::Attachment.count
    sign_in_as @owner

    patch vessel_path(@vessel), params: {
      asset: {
        name: "Blocked vessel update",
        primary_photo: fixture_file_upload("sample.png", "image/png")
      }
    }
    assert_response :not_found
    assert_equal "Entitlement Vessel", @vessel.reload.name
    assert_equal photo_blob_id, @vessel.primary_photo.blob.id

    assert_no_difference -> { Document.count } do
      post vessel_documents_path(@vessel), params: {
        document: {
          title: "Blocked document",
          document_type: "other",
          file: fixture_file_upload("sample.png", "image/png")
        }
      }
    end
    assert_response :not_found

    patch document_path(document), params: {
      document: {
        title: "Blocked replacement",
        document_type: document.document_type,
        file: fixture_file_upload("sample.png", "image/png")
      }
    }
    assert_response :not_found
    assert_equal "Existing registration", document.reload.title
    assert_equal document_blob_id, document.file.blob.id

    assert_no_difference -> { Document.count } do
      delete document_path(document)
    end
    assert_response :not_found

    assert_no_difference -> { Reminder.count } do
      post reminders_path, params: {
        reminder: {
          asset_id: @vessel.id,
          title: "Blocked reminder",
          due_date: Date.tomorrow,
          reminder_type: "maintenance"
        }
      }
    end
    assert_access_denied_redirect

    patch reminder_path(reminder), params: {
      reminder: {
        asset_id: @vessel.id,
        title: "Blocked reminder update",
        due_date: reminder.due_date,
        reminder_type: reminder.reminder_type
      }
    }
    assert_access_denied_redirect
    assert_equal "Existing reminder", reminder.reload.title

    patch reminder_path(reminder, status_action: "complete"), params: {
      reminder: { asset_id: @vessel.id }
    }
    assert_access_denied_redirect
    assert_equal "pending", reminder.reload.status

    patch reminder_path(completed_reminder, status_action: "reopen"), params: {
      reminder: { asset_id: @vessel.id }
    }
    assert_access_denied_redirect
    assert_equal "completed", completed_reminder.reload.status

    assert_no_difference -> { BinderNote.count } do
      post vessel_binder_notes_path(@vessel), params: {
        binder_note: { title: "Blocked note", body: "Blocked", note_type: "general" }
      }
    end
    assert_access_denied_redirect

    patch vessel_binder_note_path(@vessel, note), params: {
      binder_note: { title: "Blocked note update", body: note.body, note_type: note.note_type }
    }
    assert_access_denied_redirect
    assert_equal "Existing note", note.reload.title

    assert_no_difference -> { BinderNote.count } do
      delete vessel_binder_note_path(@vessel, note)
    end
    assert_access_denied_redirect

    delete primary_photo_vessel_path(@vessel)
    assert_response :not_found
    assert_equal photo_blob_id, @vessel.reload.primary_photo.blob.id
    assert_equal original_blob_count, ActiveStorage::Blob.count
    assert_equal original_attachment_count, ActiveStorage::Attachment.count
  end

  test "read only grace editor retains reads and loses existing write controls" do
    document = @vessel.documents.create!(
      account: @account,
      title: "Readable document",
      document_type: "other"
    )
    reminder = @vessel.reminders.create!(
      title: "Readable reminder",
      due_date: Date.tomorrow,
      reminder_type: "maintenance",
      status: "pending"
    )
    note = @vessel.binder_notes.create!(
      account: @account,
      title: "Readable note",
      body: "Still available",
      note_type: "general"
    )
    @account.subscription.update!(
      provider: Subscription::STRIPE_PROVIDER,
      plan: "self_managed",
      status: "canceled",
      external_customer_id: "cus_#{@account.id}",
      external_subscription_id: "sub_#{@account.id}",
      entitlement_ended_at: @now - 1.day,
      last_synced_at: @now - 1.minute
    )
    sign_in_as @owner

    travel_to @now do
      get vessel_path(@vessel)

      assert_response :success
      assert_includes response.body, document.title
      assert_includes response.body, reminder.title
      assert_includes response.body, note.title
      assert_select "a[href=?]", edit_vessel_path(@vessel), count: 0
      assert_select "a[href=?]", new_vessel_document_path(@vessel), count: 0
      assert_select "form[action=?]", vessel_binder_notes_path(@vessel), count: 0
      assert_select "a[href=?]", edit_vessel_binder_note_path(@vessel, note), count: 0

      get document_path(document)
      assert_response :success
      assert_select "a[href=?]", edit_document_path(document), count: 0
      assert_select "form[action=?]", document_path(document), count: 0

      get reminders_path
      assert_response :success
      assert_includes response.body, reminder.title
      assert_select "a[href=?]", edit_reminder_path(reminder), count: 0
      assert_select "form[action=?]", reminder_path(reminder, status_action: "complete"), count: 0
    end
  end

  test "qualifying entitlement cannot replace account membership scope" do
    qualify_self_managed_subscription(@account, now: @now)
    other_account = create_account(name: "Unassigned Qualifying Account")
    qualify_self_managed_subscription(other_account, now: @now)
    other_vessel = create_vessel(account: other_account, name: "Private Vessel")
    sign_in_as @owner

    patch vessel_path(other_vessel), params: { asset: { name: "Blocked cross-account update" } }

    assert_response :not_found
    assert_equal "Private Vessel", other_vessel.reload.name
  end

  test "read only and inactive editor memberships remain non writable with qualifying entitlement" do
    qualify_self_managed_subscription(@account, now: @now)
    read_only_owner = create_user(email: "entitled-read-only@example.test", role: "owner")
    create_account_membership(user: read_only_owner, account: @account, access_level: "read_only")
    inactive_editor = create_user(email: "entitled-inactive-editor@example.test", role: "owner")
    create_account_membership(
      user: inactive_editor,
      account: @account,
      access_level: "editor",
      active: false
    )

    sign_in_as read_only_owner
    patch vessel_path(@vessel), params: { asset: { name: "Blocked read only update" } }
    assert_access_denied_redirect
    assert_equal "Entitlement Vessel", @vessel.reload.name

    sign_in_as inactive_editor
    patch vessel_path(@vessel), params: { asset: { name: "Blocked inactive membership update" } }
    assert_response :not_found
    assert_equal "Entitlement Vessel", @vessel.reload.name
  end

  test "inactive account is not writable even with qualifying entitlement" do
    qualify_self_managed_subscription(@account, now: @now)
    @account.update!(active: false)
    sign_in_as @owner

    patch vessel_path(@vessel), params: { asset: { name: "Blocked inactive account update" } }

    assert_response :not_found
    assert_equal "Entitlement Vessel", @vessel.reload.name
  end

  private

  def configure_verified_subscription(status: "active", trial_ends_at: @now + 7.days,
    current_period_ends_at: @now + 1.month, cancel_at_period_end: false)
    subscription = @account.reload.subscription || @account.create_subscription!(Subscription.default_local_attributes)
    subscription.update!(
      provider: Subscription::STRIPE_PROVIDER,
      plan: "self_managed",
      status:,
      external_customer_id: "cus_#{@account.id}",
      external_subscription_id: "sub_#{@account.id}",
      trial_ends_at:,
      current_period_ends_at:,
      cancel_at_period_end:,
      last_synced_at: @now - 1.minute
    )
    subscription
  end

  def assert_denied_vessel_update(label)
    original_name = @vessel.reload.name

    patch vessel_path(@vessel), params: { asset: { name: "Blocked #{label}" } }

    lifecycle_phase = Billing::SelfManagedEntitlement.new(account: @account, now: @now).lifecycle_phase
    if Authorization::OWNER_READABLE_LIFECYCLE_PHASES.include?(lifecycle_phase)
      assert_access_denied_redirect
    else
      assert_response :not_found
    end
    assert_equal original_name, @vessel.reload.name, "#{label} should not grant write access"
  end

  def without_stripe_subscription_retrieval
    original_retrieve = Stripe::Subscription.method(:retrieve)
    Stripe::Subscription.define_singleton_method(:retrieve) do |*|
      raise "Authorization called Stripe"
    end
    yield
  ensure
    Stripe::Subscription.define_singleton_method(:retrieve, original_retrieve)
  end
end
