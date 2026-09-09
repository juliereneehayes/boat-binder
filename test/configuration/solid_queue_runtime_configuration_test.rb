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
end
