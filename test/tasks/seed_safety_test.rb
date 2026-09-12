require "test_helper"
require "rake"

class SeedSafetyTest < ActiveSupport::TestCase
  SEED_PATH = Rails.root.join("db/seeds.rb")

  test "production seed aborts without mutating application data" do
    account = create_account(name: "Protected Production Account")
    vessel = create_vessel(account: account, name: "Protected Production Vessel")
    production = ActiveSupport::EnvironmentInquirer.new("production")

    error = assert_raises(DatabaseSeedSafety::ProhibitedEnvironmentError) do
      DatabaseSeedSafety.ensure_allowed!(environment: production)
    end

    assert_includes error.message, "Production database seeding is prohibited"
    assert Account.exists?(account.id)
    assert Asset.exists?(vessel.id)
    assert_equal "DatabaseSeedSafety.ensure_allowed!", File.readlines(SEED_PATH).first.strip
  end

  test "non production seed is non destructive and creates no users" do
    account = create_account(name: "Existing Development Account")
    user = create_user(email: "existing@example.test", role: "admin")

    assert_no_difference [ -> { Account.count }, -> { User.count }, -> { Asset.count } ] do
      load SEED_PATH
    end

    assert Account.exists?(account.id)
    assert User.exists?(user.id)
  end

  test "authoritative seed and demo paths contain no historical default credentials" do
    source_paths = [
      SEED_PATH,
      Rails.root.join("app/services/build_week/demo_account_setup.rb"),
      Rails.root.join("lib/tasks/demo.rake"),
      Rails.root.join("lib/tasks/database_seed_safety.rake")
    ]
    seed_source = source_paths.map { |path| File.read(path) }.join("\n")

    assert_not_includes seed_source, "admin@hayesyacht.test"
    assert_not_includes seed_source, "captain@hayesyacht.test"
    refute_match(/DEFAULT_PASSWORD|password:\s*["']password["']/, seed_source)
  end

  test "production guard is a prerequisite for seed and seed replant tasks" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("db:seed:production_guard")

    seed_prerequisites = Rake::Task["db:seed"].prerequisites
    replant_prerequisites = Rake::Task["db:seed:replant"].prerequisites

    assert_equal "db:seed:production_guard", seed_prerequisites.first
    assert_equal "db:seed:production_guard", replant_prerequisites.first
    assert_operator replant_prerequisites.index("db:seed:production_guard"), :<,
      replant_prerequisites.index("truncate_all")
  end
end
