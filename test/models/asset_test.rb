require "test_helper"

class AssetTest < ActiveSupport::TestCase
  test "requires a name" do
    asset = Asset.new(account: create_account, asset_type: "vessel")

    assert_not asset.valid?
    assert_includes asset.errors[:name], "can't be blank"
  end

  test "requires a supported asset type" do
    asset = Asset.new(account: create_account, name: "Blue Meridian", asset_type: "vehicle")

    assert_not asset.valid?
    assert_includes asset.errors[:asset_type], "is not included in the list"
  end

  test "keeps vessel helpers for the captain workflow" do
    account = create_account(name: "Elliott Family")
    account.contacts.create!(name: "Avery Elliott", role: "Owner")
    asset = create_vessel(account: account)
    user = create_user
    older = asset.service_visits.create!(performed_by_user: user, visit_date: 2.days.ago.to_date)
    newer = asset.service_visits.create!(performed_by_user: user, visit_date: Date.current)

    assert_equal "Avery Elliott", asset.owner_name
    assert_equal newer, asset.last_visit
    assert_includes asset.service_visits, older
  end

  test "surfaces attention state from overdue reminders" do
    asset = create_vessel
    asset.reminders.create!(title: "Replace zincs", due_date: Date.yesterday, reminder_type: "maintenance")

    assert_equal "Needs attention", asset.status_label
    assert_equal :urgent, asset.status_tone
  end

  test "account today uses the account local date" do
    account = create_account(time_zone: "America/New_York")
    vessel = create_vessel(account: account)

    travel_to Time.utc(2026, 7, 6, 3, 30) do
      assert_equal Date.new(2026, 7, 5), vessel.send(:account_today)
    end
  end

  test "account today falls back safely when the persisted account time zone is invalid" do
    account = create_account(time_zone: "America/New_York")
    account.update_column(:time_zone, "Mars/Base")
    vessel = create_vessel(account: account)

    travel_to Time.utc(2026, 7, 6, 3, 30) do
      assert_equal Time.zone.today, vessel.send(:account_today)
    end
  end

  test "generates readable unique slugs and uses them in routes" do
    account = create_account(name: "Elliott Family")
    first = create_vessel(account: account)
    second = Asset.create!(account: create_account(name: "Second Owner"), asset_type: "vessel", name: first.name)

    assert_equal "blue-meridian", first.slug
    assert_equal "blue-meridian-2", second.slug
    assert_equal first.slug, first.to_param
  end

  test "searches vessels by name owner marina and slip" do
    account = create_account(name: "Elliott Family")
    account.contacts.create!(name: "Avery Elliott", email: "avery@example.test", role: "Owner")
    vessel = create_vessel(account: account)

    assert_includes Asset.vessels.search("Blue").to_a, vessel
    assert_includes Asset.vessels.search("Avery").to_a, vessel
    assert_includes Asset.vessels.search("Elliott").to_a, vessel
    assert_includes Asset.vessels.search("Avery Elliott").to_a, vessel
    assert_includes Asset.vessels.search("Bainbridge").to_a, vessel
    assert_includes Asset.vessels.search("Bainbridge Marina").to_a, vessel
    assert_includes Asset.vessels.search("C-18").to_a, vessel
  end

  test "inactive vessels keep history but read as inactive" do
    vessel = create_vessel
    vessel.update!(active: false)

    assert_equal "Inactive", vessel.status_label
    assert_equal :neutral, vessel.status_tone
    assert_includes Asset.vessels.inactive, vessel
  end

  test "owner can have multiple vessels" do
    account = create_account(name: "Elliott Family")
    first = create_vessel(account: account)
    second = Asset.create!(account: account, asset_type: "vessel", name: "Harbor Light")

    assert_equal [ first, second ].sort_by(&:id), account.assets.vessels.to_a.sort_by(&:id)
  end

  test "restricted access information blocks account reassignment through the model" do
    source_account = create_account(name: "Protected Reassignment Source")
    source_account.create_managed_service_relationship!(active: true)
    target_account = create_account(name: "Protected Reassignment Target")
    vessel = create_vessel(account: source_account, name: "Protected Reassignment Vessel")
    actor = create_user(email: "protected-reassignment-admin@example.test", role: "admin")
    record = VesselAccessInformation::Persistence.save!(
      vessel:,
      restricted_details: "Synthetic reassignment credential 4815",
      actor:
    )

    assert_not vessel.update(account: target_account)
    assert_includes vessel.errors[:account],
      "cannot be changed while restricted access information is retained"
    assert_equal source_account, vessel.reload.account
    assert_equal vessel, record.reload.vessel
  end

  test "changing Vessel type cannot bypass protected account reassignment" do
    source_account = create_account(name: "Protected Type Source")
    source_account.create_managed_service_relationship!(active: true)
    target_account = create_account(name: "Protected Type Target")
    vessel = create_vessel(account: source_account, name: "Protected Type Vessel")
    actor = create_user(email: "protected-type-admin@example.test", role: "admin")
    record = VesselAccessInformation::Persistence.save!(
      vessel:,
      restricted_details: "Synthetic protected type credential 7051",
      actor:
    )

    assert_not vessel.update(account: target_account, asset_type: "home")
    assert_includes vessel.errors[:account],
      "cannot be changed while restricted access information is retained"
    assert_includes vessel.errors[:asset_type],
      "cannot be changed while restricted access information is retained"
    assert_equal source_account, vessel.reload.account
    assert_equal "vessel", vessel.asset_type
    assert_equal vessel, record.reload.vessel

    assert_not vessel.update(asset_type: "home")
    assert_includes vessel.errors[:asset_type],
      "cannot be changed while restricted access information is retained"
    assert_equal "vessel", vessel.reload.asset_type
  end

  test "encrypted access information fails fast before Vessel associations are deleted" do
    account = create_account(name: "Protected Asset Account")
    account.create_managed_service_relationship!(active: true)
    vessel = create_vessel(account:)
    actor = create_user(email: "protected-asset-admin@example.test", role: "admin")
    document = vessel.documents.create!(account:, title: "Retained Document", document_type: "other")
    engine = vessel.asset_engines.create!(name: "Retained Engine")
    battery = vessel.asset_batteries.create!(name: "Retained Battery")
    record = VesselAccessInformation::Persistence.save!(
      vessel:,
      restricted_details: "Synthetic protected asset value",
      actor:
    )

    assert_raises(ActiveRecord::DeleteRestrictionError) { vessel.destroy! }

    assert Asset.exists?(vessel.id)
    assert Document.exists?(document.id)
    assert AssetEngine.exists?(engine.id)
    assert AssetBattery.exists?(battery.id)
    assert VesselAccessInformation.exists?(record.id)
  end

  test "Vessel without restricted information still deletes its destructive associations" do
    vessel = create_vessel(name: "Deletable Associated Vessel")
    document = vessel.documents.create!(
      account: vessel.account,
      title: "Deletable Document",
      document_type: "other"
    )
    engine = vessel.asset_engines.create!(name: "Deletable Engine")
    battery = vessel.asset_batteries.create!(name: "Deletable Battery")

    vessel.destroy!

    assert_not Asset.exists?(vessel.id)
    assert_not Document.exists?(document.id)
    assert_not AssetEngine.exists?(engine.id)
    assert_not AssetBattery.exists?(battery.id)
  end

  test "metadata edits preserve a legacy primary photo with a mismatched extension" do
    vessel = create_vessel
    blob = ActiveStorage::Blob.create_and_upload!(
      io: file_fixture("sample.jpg").open,
      filename: "legacy.bin",
      content_type: "image/jpeg",
      identify: false
    )
    ActiveStorage::Attachment.create!(name: "primary_photo", record: vessel, blob:)

    vessel.update!(marina: "Updated Marina")

    assert_equal blob.id, vessel.reload.primary_photo.blob.id
  end


  test "optional operating instructions preserve line breaks normalize blanks and enforce a bounded length" do
    vessel = create_vessel
    vessel.update!(
      engine_startup_instructions: "  Start blower.\nWait five minutes.  ",
      engine_shutdown_instructions: "   ",
      battery_shore_power_instructions: "Disconnect synthetic shore power.",
      operating_notes: nil
    )

    vessel.reload
    assert_equal "Start blower.\nWait five minutes.", vessel.engine_startup_instructions
    assert_nil vessel.engine_shutdown_instructions
    assert_equal "Disconnect synthetic shore power.", vessel.battery_shore_power_instructions
    assert_nil vessel.operating_notes

    vessel.operating_notes = "a" * (Asset::OPERATING_INSTRUCTION_MAX_LENGTH + 1)
    assert_not vessel.valid?
    assert_includes vessel.errors[:operating_notes],
      "is too long (maximum is #{Asset::OPERATING_INSTRUCTION_MAX_LENGTH} characters)"
  end
end
