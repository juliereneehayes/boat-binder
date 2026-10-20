require "test_helper"
require "rake"

class SeedSafetyTest < ActiveSupport::TestCase
  SEED_PATH = Rails.root.join("db/seeds.rb")
  RETIRED_DEMO_PATHS = [
    Rails.root.join("app/services/build_week/demo_account_setup.rb"),
    Rails.root.join("lib/tasks/demo.rake"),
    Rails.root.join("db/seeds/build_week_demo.rb")
  ].freeze
  RETIRED_DEMO_CONFIG_KEYS = %w[
    BUILD_WEEK_DEMO_EMAIL
    BUILD_WEEK_DEMO_PASSWORD
    BUILD_WEEK_DEMO_ALLOWED_ENVIRONMENTS
    BUILD_WEEK_DEMO_CONFIRMATION
  ].freeze
  RETIRED_DEMO_DUMMY_CONFIG = {
    "BUILD_WEEK_DEMO_EMAIL" => "retired-demo-placeholder@example.test",
    "BUILD_WEEK_DEMO_PASSWORD" => "not-a-real-password",
    "BUILD_WEEK_DEMO_ALLOWED_ENVIRONMENTS" => "development",
    "BUILD_WEEK_DEMO_CONFIRMATION" => "NOT A REAL CONFIRMATION"
  }.freeze

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

  test "non production seed is non destructive and creates no users without retired demo config" do
    account = create_account(name: "Existing Development Account")
    user = create_user(email: "existing@example.test", role: "admin")

    without_environment_variables(*RETIRED_DEMO_CONFIG_KEYS) do
      assert_no_difference [ -> { Account.count }, -> { User.count }, -> { Asset.count } ] do
        load SEED_PATH
      end
    end

    assert Account.exists?(account.id)
    assert User.exists?(user.id)
  end

  test "stale retired demo config does not affect ordinary seeds" do
    account = create_account(name: "Account Preserved With Stale Config")
    user = create_user(email: "stale-config-existing@example.test", role: "admin")
    vessel = create_vessel(account: account, name: "Vessel Preserved With Stale Config")
    original_attributes = [ account.attributes, user.attributes, vessel.attributes ]

    with_environment_variables(RETIRED_DEMO_DUMMY_CONFIG) do
      assert_no_difference [ -> { Account.count }, -> { User.count }, -> { Asset.count } ] do
        load SEED_PATH
      end
    end

    assert_equal original_attributes[0], account.reload.attributes
    assert_equal original_attributes[1], user.reload.attributes
    assert_equal original_attributes[2], vessel.reload.attributes
  end

  test "authoritative seed paths contain no historical default credentials" do
    source_paths = [
      SEED_PATH,
      Rails.root.join("lib/tasks/database_seed_safety.rake")
    ]
    seed_source = source_paths.map { |path| File.read(path) }.join("\n")

    assert_not_includes seed_source, "admin@hayesyacht.test"
    assert_not_includes seed_source, "captain@hayesyacht.test"
    refute_match(/DEFAULT_PASSWORD|password:\s*["']password["']/, seed_source)
  end

  test "retired Build Week demo code and reset task are absent" do
    RETIRED_DEMO_PATHS.each { |path| assert_not path.exist?, "Expected #{path} to be removed" }

    Rails.application.load_tasks unless Rake::Task.task_defined?("db:seed:production_guard")

    assert_not Rake::Task.task_defined?("demo:reset")
    assert_not defined?(BuildWeek::DemoAccountSetup)
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

  private

  def without_environment_variables(*keys)
    with_environment_variables(keys.index_with { nil }) { yield }
  end

  def with_environment_variables(values)
    previous_values = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
    yield
  ensure
    previous_values.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end
end
