require "test_helper"
require "stringio"

class BuildWeekDemoAccountSetupTest < ActiveSupport::TestCase
  DEMO_EMAIL = "build-week-demo@example.test"
  DEMO_PASSWORD = "super-secret-demo-password"

  setup do
    @previous_email = ENV["BUILD_WEEK_DEMO_EMAIL"]
    @previous_password = ENV["BUILD_WEEK_DEMO_PASSWORD"]
    ENV["BUILD_WEEK_DEMO_EMAIL"] = DEMO_EMAIL
    ENV["BUILD_WEEK_DEMO_PASSWORD"] = DEMO_PASSWORD
  end

  teardown do
    restore_env("BUILD_WEEK_DEMO_EMAIL", @previous_email)
    restore_env("BUILD_WEEK_DEMO_PASSWORD", @previous_password)
  end

  test "first run creates the expected demo user account and content" do
    output = StringIO.new

    assert_difference -> { Account.count }, 1 do
      assert_difference -> { User.count }, 1 do
        assert_difference -> { Subscription.count }, 1 do
          assert_difference -> { AccountMembership.count }, 1 do
            result = BuildWeek::DemoAccountSetup.call(output: output)

            assert_equal "Alex Johnson", result.account.name
            assert_equal DEMO_EMAIL, result.user.email_address
          end
        end
      end
    end

    account = Account.find_by!(name: "Alex Johnson")
    user = User.find_by!(email_address: DEMO_EMAIL)

    assert_equal "client", account.account_type
    assert_equal "America/Los_Angeles", account.time_zone
    assert account.active?
    assert user.owner?
    assert user.active?
    assert user.authenticate(DEMO_PASSWORD)
    assert_includes account.notes, BuildWeek::DemoAccountSetup::DEMO_MARKER
    assert_equal %w[Reel\ Escape Sea\ Breeze], account.assets.vessels.order(:name).pluck(:name)
    assert_equal 5, account.documents.count
    assert_equal 4, account.assets.joins(:service_visits).count
    assert_equal 5, account.assets.joins(:reminders).count
    assert_equal 4, account.binder_notes.count
    assert_not_includes output.string, DEMO_PASSWORD
    assert_includes output.string, "Build Week demo account refreshed."
    assert_includes output.string, "Password: set from BUILD_WEEK_DEMO_PASSWORD; production requires this variable."
  end

  test "environment restoration deletes originally unset variables and restores present ones" do
    ENV["BUILD_WEEK_DEMO_EMAIL"] = "temporary@example.test"
    ENV["BUILD_WEEK_DEMO_PASSWORD"] = "temporary-password"

    restore_env("BUILD_WEEK_DEMO_EMAIL", nil)
    restore_env("BUILD_WEEK_DEMO_PASSWORD", "previous-password")

    assert_nil ENV["BUILD_WEEK_DEMO_EMAIL"]
    assert_equal "previous-password", ENV["BUILD_WEEK_DEMO_PASSWORD"]
  end

  test "second run refreshes without duplicating core records" do
    first_output = StringIO.new
    BuildWeek::DemoAccountSetup.call(output: first_output)
    account = Account.find_by!(name: "Alex Johnson")

    counts_after_first_run = {
      accounts: Account.count,
      users: User.count,
      memberships: AccountMembership.count,
      subscriptions: Subscription.count,
      vessels: account.assets.vessels.count,
      documents: account.documents.count,
      service_visits: ServiceVisit.joins(:asset).where(assets: { account_id: account.id }).count,
      reminders: Reminder.joins(:asset).where(assets: { account_id: account.id }).count
    }

    second_output = StringIO.new
    BuildWeek::DemoAccountSetup.call(output: second_output)
    account.reload

    assert_equal counts_after_first_run.fetch(:accounts), Account.count
    assert_equal counts_after_first_run.fetch(:users), User.count
    assert_equal counts_after_first_run.fetch(:memberships), AccountMembership.count
    assert_equal counts_after_first_run.fetch(:subscriptions), Subscription.count
    assert_equal counts_after_first_run.fetch(:vessels), account.assets.vessels.count
    assert_equal counts_after_first_run.fetch(:documents), account.documents.count
    assert_equal counts_after_first_run.fetch(:service_visits),
      ServiceVisit.joins(:asset).where(assets: { account_id: account.id }).count
    assert_equal counts_after_first_run.fetch(:reminders),
      Reminder.joins(:asset).where(assets: { account_id: account.id }).count
    assert_not_includes second_output.string, DEMO_PASSWORD
  end

  test "failed refresh preserves existing records and attachment files after rollback" do
    BuildWeek::DemoAccountSetup.call(output: StringIO.new)
    account = Account.find_by!(name: "Alex Johnson")
    document = account.documents.first
    vessel = account.assets.vessels.first
    document.file.attach(uploaded_file("sample.pdf", "application/pdf"))
    vessel.primary_photo.attach(uploaded_file("sample.jpg", "image/jpeg"))
    document_blob_id = document.file.blob.id
    vessel_blob_id = vessel.primary_photo.blob.id
    original_document_ids = account.documents.pluck(:id)
    original_asset_ids = account.assets.pluck(:id)

    setup = BuildWeek::DemoAccountSetup.new(output: StringIO.new)
    setup.define_singleton_method(:create_vessels) { |*| raise "controlled refresh failure" }

    assert_raises(RuntimeError) { setup.call }

    assert_equal original_document_ids.sort, account.documents.reload.pluck(:id).sort
    assert_equal original_asset_ids.sort, account.assets.reload.pluck(:id).sort
    assert Document.exists?(document.id)
    assert Asset.exists?(vessel.id)
    assert ActiveStorage::Blob.exists?(document_blob_id)
    assert ActiveStorage::Blob.exists?(vessel_blob_id)
    assert document.reload.file.attached?
    assert vessel.reload.primary_photo.attached?
    assert document.file.download.bytesize.positive?
    assert vessel.primary_photo.download.bytesize.positive?
  end

  test "successful refresh destroys old demo records and recreates intended content" do
    BuildWeek::DemoAccountSetup.call(output: StringIO.new)
    account = Account.find_by!(name: "Alex Johnson")
    old_document = account.documents.first
    old_vessel = account.assets.vessels.first
    old_document.file.attach(uploaded_file("sample.pdf", "application/pdf"))
    old_vessel.primary_photo.attach(uploaded_file("sample.jpg", "image/jpeg"))
    old_document_id = old_document.id
    old_vessel_id = old_vessel.id
    old_document_attachment_id = old_document.file.attachment.id
    old_photo_attachment_id = old_vessel.primary_photo.attachment.id

    BuildWeek::DemoAccountSetup.call(output: StringIO.new)
    account.reload

    assert_not Document.exists?(old_document_id)
    assert_not Asset.exists?(old_vessel_id)
    assert_not ActiveStorage::Attachment.exists?(old_document_attachment_id)
    assert_not ActiveStorage::Attachment.exists?(old_photo_attachment_id)
    assert_equal %w[Reel\ Escape Sea\ Breeze], account.assets.vessels.order(:name).pluck(:name)
    assert_equal 5, account.documents.count
    assert_equal 4, account.assets.joins(:service_visits).count
    assert_equal 5, account.assets.joins(:reminders).count
  end

  test "existing marked demo account is refreshed" do
    account = Account.create!(
      name: "Alex Johnson",
      account_type: "client",
      active: false,
      time_zone: "America/Los_Angeles",
      notes: "#{BuildWeek::DemoAccountSetup::DEMO_MARKER} Keep this operator note."
    )

    result = BuildWeek::DemoAccountSetup.call(output: StringIO.new)

    assert_equal account.id, result.account.id
    assert result.account.reload.active?
    assert_includes result.account.notes, BuildWeek::DemoAccountSetup::DEMO_MARKER
    assert_includes result.account.notes, "Keep this operator note."
  end

  test "unrelated accounts are untouched" do
    unrelated = create_account(name: "Unrelated Owner")
    unrelated_vessel = create_vessel(account: unrelated, name: "Unrelated Vessel")

    BuildWeek::DemoAccountSetup.call(output: StringIO.new)

    assert Account.exists?(unrelated.id)
    assert Asset.exists?(unrelated_vessel.id)
    assert_equal "Unrelated Owner", unrelated.reload.name
    assert_equal "Unrelated Vessel", unrelated_vessel.reload.name
  end

  test "demo owner has active writable membership and valid local subscription" do
    BuildWeek::DemoAccountSetup.call(output: StringIO.new)

    account = Account.find_by!(name: "Alex Johnson")
    user = User.find_by!(email_address: DEMO_EMAIL).reload
    membership = AccountMembership.find_by!(account: account, user: user)
    subscription = account.subscription

    assert membership.active?
    assert_equal "editor", membership.access_level
    assert subscription.valid?
    assert_equal "legacy", subscription.plan
    assert_equal "active", subscription.status
    assert_equal "local", subscription.provider
    assert subscription.access_allowed?
    assert_not subscription.managed_externally?
    assert_nil subscription.external_customer_id
    assert_nil subscription.external_subscription_id
  end

  test "demo owner remains scoped away from unrelated accounts" do
    unrelated = create_account(name: "Unrelated Private Owner")

    result = BuildWeek::DemoAccountSetup.call(output: StringIO.new)

    account = result.account
    user = User.find_by!(email_address: DEMO_EMAIL).reload
    visible_account_ids = Account.where(id: user.active_account_ids).pluck(:id)

    assert user.owner?
    assert_equal [ account.id ], visible_account_ids
    assert_not_includes visible_account_ids, unrelated.id
  end

  test "conflicting non demo account is rejected clearly" do
    account = create_account(name: "Alex Johnson")

    error = assert_raises(BuildWeek::DemoAccountSetup::ConflictError) do
      BuildWeek::DemoAccountSetup.call(output: StringIO.new)
    end

    assert_includes error.message, "not marked as the Build Week demo account"
    assert_nil account.reload.notes
  end

  test "same-name account with nil notes is treated as unmarked" do
    account = create_account(name: "Alex Johnson")
    account.update!(notes: nil)

    assert_raises(BuildWeek::DemoAccountSetup::ConflictError) do
      BuildWeek::DemoAccountSetup.call(output: StringIO.new)
    end

    assert_nil account.reload.notes
  end

  test "marked same-name account is selected when an unmarked same-name account exists" do
    unmarked = create_account(name: "Alex Johnson")
    unmarked.update!(notes: "Real customer account notes.")
    marked = Account.create!(
      name: "Alex Johnson",
      account_type: "client",
      active: true,
      time_zone: "America/Los_Angeles",
      notes: "#{BuildWeek::DemoAccountSetup::DEMO_MARKER} Existing fictional demo account."
    )

    result = BuildWeek::DemoAccountSetup.call(output: StringIO.new)

    assert_equal marked.id, result.account.id
    assert_equal "Real customer account notes.", unmarked.reload.notes
    assert_empty unmarked.assets
    assert_not_equal unmarked.id, result.user.account_memberships.sole.account_id
  end

  test "multiple marked same-name demo accounts raise a clear conflict" do
    2.times do |index|
      Account.create!(
        name: "Alex Johnson",
        account_type: "client",
        active: true,
        time_zone: "America/Los_Angeles",
        notes: "#{BuildWeek::DemoAccountSetup::DEMO_MARKER} Duplicate #{index}."
      )
    end

    error = assert_raises(BuildWeek::DemoAccountSetup::ConflictError) do
      BuildWeek::DemoAccountSetup.call(output: StringIO.new)
    end

    assert_includes error.message, "Multiple Build Week demo accounts exist"
  end

  private

  def uploaded_file(filename, content_type)
    Rack::Test::UploadedFile.new(file_fixture(filename).to_s, content_type, true)
  end

  def restore_env(name, previous_value)
    previous_value.nil? ? ENV.delete(name) : ENV[name] = previous_value
  end
end
