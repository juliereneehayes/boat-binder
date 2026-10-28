# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"
require Rails.root.join("lib/managed_backup_monitor")

class ManagedBackupMonitorTest < ActiveSupport::TestCase
  NOW = Time.utc(2026, 1, 2, 12)
  FakeResponse = Data.define(:code, :body)

  class StubHerokuClient < ManagedBackupMonitor::HerokuClient
    attr_reader :request_count, :retry_delays

    def initialize(responses:)
      @responses = responses
      @request_count = 0
      @retry_delays = []
      sleeper = Object.new
      retry_delays = @retry_delays
      sleeper.define_singleton_method(:sleep) { |delay| retry_delays << delay }
      super(token: "fixture-token", app: "fixture-app", sleeper:)
    end

    private

    def request(**)
      @request_count += 1
      response = @responses.shift
      raise response if response.is_a?(Exception)

      response
    end
  end

  class FakeClient
    attr_accessor :attachment, :schedules, :transfers, :details, :errors
    attr_reader :detail_requests

    def initialize(attachment:, schedules:, transfers:, details: {})
      @attachment = attachment
      @schedules = schedules
      @transfers = transfers
      @details = details
      @errors = {}
      @detail_requests = []
    end

    def database_attachment
      raise errors[:database_attachment] if errors[:database_attachment]

      duplicate(attachment)
    end

    def transfer_schedules(_addon_id)
      raise errors[:transfer_schedules] if errors[:transfer_schedules]

      duplicate(schedules)
    end

    def transfers
      raise errors[:transfers] if errors[:transfers]

      duplicate(@transfers)
    end

    def transfer_detail(number)
      detail_requests << number
      raise errors[:transfer_detail] if errors[:transfer_detail]

      duplicate(details.fetch(number))
    end

    private

    def duplicate(value)
      JSON.parse(JSON.generate(value))
    end
  end

  setup do
    @attachment = fixture_json("database_attachment")
    @schedule = fixture_json("schedule_one")
    @transfers = fixture_json("transfers")
    @success = fixture_json("detail_success")
    @failed = fixture_json("detail_failed")
    @running = fixture_json("detail_running")
  end

  test "healthy scheduled backup passes all checks" do
    client = build_client(details: { 106 => @success })

    assert_result "healthy", client
  end

  test "missing database attachment fails closed" do
    client = build_client
    client.attachment = nil

    assert_result "database_resolution_failed", client
  end

  test "malformed database response is a schema error" do
    client = build_client
    client.attachment = { "addon" => "fixture-addon-id" }

    assert_result "schema_error", client
  end

  test "authorization failure during database resolution is sanitized" do
    client = build_client
    client.errors[:database_attachment] = ManagedBackupMonitor::AuthorizationError.new("raw provider detail")

    assert_result "authorization_failed", client
  end

  test "other endpoint failure prevents a health determination" do
    client = build_client
    client.errors[:database_attachment] = ManagedBackupMonitor::RequestError.new("raw provider detail")

    assert_result "check_error", client
  end

  test "transient HTTP failure retries once and succeeds" do
    client = StubHerokuClient.new(responses: [
      response(429),
      response(200, JSON.generate(@attachment))
    ])

    assert_equal @attachment, client.database_attachment
    assert_equal 2, client.request_count
    assert_equal [ ManagedBackupMonitor::HerokuClient::RETRY_DELAY ], client.retry_delays
  end

  test "transient network failure retries once and succeeds" do
    client = StubHerokuClient.new(responses: [
      Net::ReadTimeout.new("fixture timeout"),
      response(200, JSON.generate(@attachment))
    ])

    assert_equal @attachment, client.database_attachment
    assert_equal 2, client.request_count
  end

  test "persistent transient failure becomes a check error after one retry" do
    client = StubHerokuClient.new(responses: [ response(503), response(503) ])

    assert_result "check_error", client
    assert_equal 2, client.request_count
  end

  test "authorization failures are not retried" do
    client = StubHerokuClient.new(responses: [ response(403), response(200, JSON.generate(@attachment)) ])

    assert_result "authorization_failed", client
    assert_equal 1, client.request_count
    assert_empty client.retry_delays
  end

  test "schema failures are not retried" do
    client = StubHerokuClient.new(responses: [ response(200, "not-json"), response(200, JSON.generate(@attachment)) ])

    assert_result "schema_error", client
    assert_equal 1, client.request_count
    assert_empty client.retry_delays
  end

  test "exactly one schedule is accepted" do
    client = build_client(details: { 106 => @success })

    assert_result "healthy", client
  end

  test "missing schedule is unhealthy" do
    client = build_client
    client.schedules = fixture_json("schedule_none")

    assert_result "schedule_missing", client
  end

  test "multiple schedules are ambiguous" do
    client = build_client
    client.schedules = fixture_json("schedule_multiple")

    assert_result "schedule_ambiguous", client
  end

  test "malformed schedule response is a schema error" do
    client = build_client
    client.schedules = { "uuid" => "fixture-schedule-id" }

    assert_result "schema_error", client
  end

  test "manual backup is ignored" do
    client = build_client
    client.transfers = [ @transfers.fetch(0) ]

    assert_result "freshness_stale", client
    assert_empty client.detail_requests
  end

  test "restore or copy is ignored" do
    client = build_client
    client.transfers = [ @transfers.fetch(1), @transfers.fetch(2) ]

    assert_result "freshness_stale", client
    assert_empty client.detail_requests
  end

  test "different schedule is ignored" do
    client = build_client
    client.transfers = [ @transfers.fetch(3) ]

    assert_result "freshness_stale", client
    assert_empty client.detail_requests
  end

  test "newest matching scheduled transfer is selected" do
    client = build_client(details: { 106 => @success, 105 => success_detail(number: 105) })

    assert_result "healthy", client
    assert_equal [ 106 ], client.detail_requests
  end

  test "failed newest scheduled backup is unhealthy" do
    client = build_client(details: { 106 => @failed })

    assert_result "scheduled_capture_failed", client
  end

  test "false success flag without completion metadata is treated as running" do
    client = build_client(details: {
      106 => @running.merge("succeeded" => false, "finished_at" => nil, "canceled_at" => nil),
      105 => success_detail(number: 105, finished_at: "2026-01-02T06:00:00Z")
    })

    assert_result "healthy", client
    assert_equal [ 106, 105 ], client.detail_requests
  end

  test "newest running then failed then older success reports the completed failure" do
    transfers = [
      scheduled_transfer(number: 108, created_at: "2026-01-02T11:30:00Z"),
      scheduled_transfer(number: 107, created_at: "2026-01-02T10:30:00Z"),
      scheduled_transfer(number: 106, created_at: "2026-01-02T09:30:00Z")
    ]
    client = build_client(details: {
      108 => running_detail(number: 108),
      107 => failed_detail(number: 107),
      106 => success_detail
    })
    client.transfers = transfers

    assert_result "scheduled_capture_failed", client
    assert_equal [ 108, 107 ], client.detail_requests
  end

  test "running newest backup does not fail when previous success is fresh" do
    client = build_client(details: {
      106 => @running,
      105 => success_detail(number: 105, finished_at: "2026-01-02T06:00:00Z")
    })

    assert_result "healthy", client
    assert_equal [ 106, 105 ], client.detail_requests
  end

  test "running newest backup is unhealthy when previous success is stale" do
    client = build_client(details: {
      106 => @running,
      105 => success_detail(number: 105, finished_at: "2026-01-01T05:59:59Z")
    })

    assert_result "freshness_stale", client
  end

  test "all candidates running within the detail cap fails closed without an eleventh request" do
    transfers = (1..11).map do |offset|
      scheduled_transfer(number: 200 + offset, created_at: (NOW - offset * 60).iso8601)
    end
    details = transfers.to_h do |transfer|
      number = transfer.fetch("num")
      [ number, running_detail(number:) ]
    end
    oldest_number = transfers.last.fetch("num")
    details[oldest_number] = success_detail(number: oldest_number)
    client = build_client(details:)
    client.transfers = transfers

    assert_result "freshness_stale", client
    assert_equal ManagedBackupMonitor::DETAIL_REQUEST_LIMIT, client.detail_requests.length
    refute_includes client.detail_requests, oldest_number
  end

  test "missing transfer detail fields fail closed" do
    client = build_client(details: { 106 => fixture_json("detail_malformed") })

    assert_result "schema_error", client
  end

  test "malformed transfer detail fails closed" do
    client = build_client(details: { 106 => [ "unexpected" ] })

    assert_result "schema_error", client
  end

  test "successful state without finished timestamp is a schema error" do
    detail = @success.merge("finished_at" => nil)
    client = build_client(details: { 106 => detail })

    assert_result "schema_error", client
  end

  test "successful state with cancellation timestamp is a schema error" do
    detail = @success.merge("canceled_at" => "2026-01-02T11:05:00Z")
    client = build_client(details: { 106 => detail })

    assert_result "schema_error", client
  end

  test "indeterminate success state with finished timestamp is a schema error" do
    detail = @success.merge("succeeded" => nil)
    client = build_client(details: { 106 => detail })

    assert_result "schema_error", client
  end

  test "failed state with cancellation timestamp is a completed failure" do
    detail = @failed.merge("finished_at" => nil, "canceled_at" => "2026-01-02T11:05:00Z")
    client = build_client(details: { 106 => detail })

    assert_result "scheduled_capture_failed", client
  end

  test "empty finished timestamp is a schema error" do
    detail = @success.merge("finished_at" => "")
    client = build_client(details: { 106 => detail })

    assert_result "schema_error", client
  end

  test "unparseable finished timestamp is a schema error" do
    detail = @success.merge("finished_at" => "not-a-timestamp")
    client = build_client(details: { 106 => detail })

    assert_result "schema_error", client
  end

  test "successful backup exactly at the 30 hour boundary is fresh" do
    client = build_client(details: { 106 => success_detail(finished_at: "2026-01-01T06:00:00Z") })

    assert_result "healthy", client
  end

  test "successful backup beyond the 30 hour boundary is stale" do
    client = build_client(details: { 106 => success_detail(finished_at: "2026-01-01T05:59:59Z") })

    assert_result "freshness_stale", client
  end

  test "alternate valid timestamp representation is accepted" do
    detail = success_detail(finished_at: "2026-01-02 11:05:00 +0000")
    client = build_client(details: { 106 => detail })

    assert_result "healthy", client
  end

  test "short numeric timestamp is rejected" do
    detail = success_detail(finished_at: "12")
    client = build_client(details: { 106 => detail })

    assert_result "schema_error", client
  end

  test "natural language timestamp is rejected" do
    detail = success_detail(finished_at: "January 2, 2026 11:05 UTC")
    client = build_client(details: { 106 => detail })

    assert_result "schema_error", client
  end

  test "small future clock skew is treated as fresh" do
    detail = success_detail(finished_at: "2026-01-02T12:05:00Z")
    client = build_client(details: { 106 => detail })

    assert_result "healthy", client
  end

  test "future clock skew beyond tolerance is a schema error" do
    detail = success_detail(finished_at: "2026-01-02T12:05:01Z")
    client = build_client(details: { 106 => detail })

    assert_result "schema_error", client
  end

  test "CLI prints only the healthy result category" do
    output = StringIO.new
    client = build_client(details: { 106 => @success })

    status = ManagedBackupMonitor::CLI.run(
      env: monitor_env,
      output:,
      client:,
      now: NOW
    )

    assert_equal 0, status
    assert_equal "managed_backup_monitor result=healthy\n", output.string
  end

  test "CLI output excludes secrets provider details identifiers URLs and timestamps" do
    output = StringIO.new
    client = build_client
    client.errors[:database_attachment] = ManagedBackupMonitor::AuthorizationError.new(
      "Authorization: Bearer fixture-token fixture-addon-id https://provider.invalid 2026-01-02T12:00:00Z"
    )

    status = ManagedBackupMonitor::CLI.run(env: monitor_env, output:, client:, now: NOW)

    assert_equal 1, status
    assert_equal "managed_backup_monitor result=authorization_failed\n", output.string
    %w[fixture-token fixture-addon-id provider.invalid 2026-01-02].each do |sensitive_value|
      refute_includes output.string, sensitive_value
    end
  end

  test "missing runtime configuration fails without naming or echoing values" do
    output = StringIO.new

    status = ManagedBackupMonitor::CLI.run(env: {}, output:, now: NOW)

    assert_equal 1, status
    assert_equal "managed_backup_monitor result=check_error\n", output.string
  end

  private

  def build_client(details: {})
    FakeClient.new(
      attachment: @attachment,
      schedules: @schedule,
      transfers: @transfers,
      details:
    )
  end

  def assert_result(expected_category, client)
    result = ManagedBackupMonitor::Monitor.new(client:, now: NOW).run

    assert_equal expected_category, result.category
  end

  def success_detail(number: 106, finished_at: "2026-01-02T11:05:00Z")
    @success.merge("num" => number, "finished_at" => finished_at)
  end

  def failed_detail(number: 106)
    @failed.merge("num" => number)
  end

  def running_detail(number: 106)
    @running.merge("num" => number)
  end

  def scheduled_transfer(number:, created_at:)
    {
      "num" => number,
      "created_at" => created_at,
      "from_type" => "pg_dump",
      "to_type" => "gof3r",
      "schedule" => { "uuid" => "fixture-schedule-id" }
    }
  end

  def response(code, body = "")
    FakeResponse.new(code: code.to_s, body:)
  end

  def fixture_json(name)
    path = Rails.root.join("test/fixtures/managed_backup_monitor/#{name}.json")
    JSON.parse(File.read(path))
  end

  def monitor_env
    {
      ManagedBackupMonitor::TOKEN_ENV => "fixture-token",
      ManagedBackupMonitor::APP_ENV => "fixture-app"
    }
  end
end
