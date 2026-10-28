# frozen_string_literal: true

require "test_helper"
require "yaml"

class ManagedBackupMonitorWorkflowTest < ActiveSupport::TestCase
  setup do
    @path = Rails.root.join(".github/workflows/managed-backup-monitor.yml")
    @source = File.read(@path)
    @workflow = YAML.safe_load(@source, aliases: true)
  end

  test "runs twice daily and can be dispatched manually" do
    triggers = @workflow.fetch("on")

    assert_equal [ { "cron" => "17 */12 * * *" } ], triggers.fetch("schedule")
    assert_equal({}, triggers.fetch("workflow_dispatch"))
    refute triggers.key?("push")
    refute triggers.key?("pull_request")
    refute triggers.key?("pull_request_target")
  end

  test "uses least privilege timeout and concurrency protection" do
    assert_equal({ "contents" => "read" }, @workflow.fetch("permissions"))
    assert_equal false, @workflow.dig("concurrency", "cancel-in-progress")
    assert_equal 5, @workflow.dig("jobs", "check", "timeout-minutes")
    refute_includes @source, "id-token:"
    refute_includes @source, "issues:"
    refute_includes @source, "deployments:"
  end

  test "uses the protected environment and canonical main branch guard" do
    job = @workflow.dig("jobs", "check")

    assert_equal "production-monitoring", job.fetch("environment")
    assert_includes job.fetch("if"), "github.repository == 'juliereneehayes/boat-binder'"
    assert_includes job.fetch("if"), "github.ref == 'refs/heads/main'"
  end

  test "exposes owner supplied configuration only to the monitor step" do
    job = @workflow.dig("jobs", "check")
    monitor_step = job.fetch("steps").find { |step| step["name"] == "Check managed backup health" }
    environment = monitor_step.fetch("env")

    assert_equal "${{ secrets.HEROKU_MANAGED_BACKUP_MONITOR_TOKEN }}",
      environment.fetch("HEROKU_MANAGED_BACKUP_MONITOR_TOKEN")
    assert_equal "${{ vars.HEROKU_MANAGED_BACKUP_MONITOR_APP }}",
      environment.fetch("HEROKU_MANAGED_BACKUP_MONITOR_APP")
    refute job.key?("env")
    job.fetch("steps").reject { |step| step.equal?(monitor_step) }.each do |step|
      refute_includes step.fetch("env", {}).keys, "HEROKU_MANAGED_BACKUP_MONITOR_TOKEN"
      refute_includes step.fetch("env", {}).keys, "HEROKU_MANAGED_BACKUP_MONITOR_APP"
    end
    assert_equal 1, @source.scan("secrets.HEROKU_MANAGED_BACKUP_MONITOR_TOKEN").length
    assert_equal 1, @source.scan("vars.HEROKU_MANAGED_BACKUP_MONITOR_APP").length
    refute_match(/HRKU-[A-Za-z0-9_-]+/, @source)
  end

  test "pins actions immutably and disables checkout credentials" do
    uses = @workflow.dig("jobs", "check", "steps").filter_map { |step| step["uses"] }

    assert uses.all? { |value| value.match?(/\A[^@]+@[0-9a-f]{40}\z/) }
    checkout = @workflow.dig("jobs", "check", "steps").find { |step| step["uses"]&.start_with?("actions/checkout@") }
    assert_equal false, checkout.dig("with", "persist-credentials")
  end

  test "runs the checked in Ruby monitor without Heroku CLI or mutation commands" do
    commands = @workflow.dig("jobs", "check", "steps").filter_map { |step| step["run"] }.join("\n")

    assert_includes commands, "ruby script/managed_backup_monitor"
    refute_match(/\bheroku\b/i, commands)
    refute_match(/backups:(capture|restore)|schedule:(create|delete)|config:set|addons:|ps:(restart|scale)/i, commands)
    refute_includes @source, "actions/upload-artifact"
    refute_includes @source, "actions/cache"
  end
end
