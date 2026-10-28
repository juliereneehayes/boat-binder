require "test_helper"

class SolidQueueRuntimeConfigurationTest < ActiveSupport::TestCase
  test "Procfile defines one dedicated async worker without a Puma executor" do
    process_lines = Rails.root.join("Procfile").readlines(chomp: true)
    puma_source = Rails.root.join("config/puma.rb").read

    assert_equal 1, process_lines.count { |line| line.start_with?("worker:") }
    assert_includes process_lines, "worker: bin/jobs --mode async"
    assert_includes process_lines, "web: bundle exec puma -C config/puma.rb"
    assert_includes process_lines, "release: bin/rails db:migrate"
    assert_predicate Rails.root.join("bin/jobs"), :executable?
    refute_includes puma_source, "plugin :solid_queue"
  end

  test "default queue concurrency fits the configured database pool" do
    queue_config = Rails.application.config_for(:queue, env: "production")
    worker_threads = queue_config.fetch(:workers).fetch(0).fetch(:threads)
    database_config = ActiveRecord::Base.configurations.configs_for(env_name: "production").fetch(0)
    pool_size = database_config.configuration_hash.fetch(:max_connections)

    assert_equal 3, worker_threads
    assert_operator pool_size, :>=, worker_threads + 2
  end

  test "production schedules stale attachment scan recovery on the background queue" do
    recurring_config = Rails.application.config_for(:recurring, env: "production")
    recovery = recurring_config.fetch(:recover_stale_attachment_scans)

    assert_equal "Storage::RecoverStaleAttachmentScansJob", recovery.fetch(:class)
    assert_equal "background", recovery.fetch(:queue)
    assert_equal "every 5 minutes", recovery.fetch(:schedule)
  end

  test "production schedules one operational health monitor on the background queue" do
    recurring_config = Rails.application.config_for(:recurring, env: "production")
    monitor = recurring_config.fetch(:monitor_operational_health)

    assert_equal "Operations::HealthMonitorJob", monitor.fetch(:class)
    assert_equal "background", monitor.fetch(:queue)
    assert_equal "every 15 minutes", monitor.fetch(:schedule)
  end
end
