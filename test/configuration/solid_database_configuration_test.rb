require "test_helper"

class SolidDatabaseConfigurationTest < ActiveSupport::TestCase
  SOLID_TABLES = %w[
    solid_cache_entries
    solid_cable_messages
    solid_queue_blocked_executions
    solid_queue_claimed_executions
    solid_queue_failed_executions
    solid_queue_jobs
    solid_queue_pauses
    solid_queue_processes
    solid_queue_ready_executions
    solid_queue_recurring_executions
    solid_queue_recurring_tasks
    solid_queue_scheduled_executions
    solid_queue_semaphores
  ].freeze

  test "production uses one primary database configuration" do
    production_configs = ActiveRecord::Base.configurations.configs_for(env_name: "production")

    assert_equal [ "primary" ], production_configs.map(&:name)
    assert_nil Rails.application.config_for(:cache, env: "production")[:database]

    cable_config = ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/cable.yml"))
    assert_nil cable_config.dig("production", "connects_to")
  end

  test "primary schema contains every Solid table" do
    SOLID_TABLES.each do |table|
      assert ActiveRecord::Base.connection.data_source_exists?(table), "Expected #{table} in the primary schema"
    end
  end
end
