# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "time"
require "uri"

module ManagedBackupMonitor
  TOKEN_ENV = "HEROKU_MANAGED_BACKUP_MONITOR_TOKEN"
  APP_ENV = "HEROKU_MANAGED_BACKUP_MONITOR_APP"
  FRESHNESS_THRESHOLD = 30 * 60 * 60
  CLOCK_SKEW_TOLERANCE = 5 * 60
  DETAIL_REQUEST_LIMIT = 10
  ALTERNATE_TIMESTAMP_FORMAT = "%Y-%m-%d %H:%M:%S %z"
  ALTERNATE_TIMESTAMP_PATTERN = /\A\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} [+-]\d{4}\z/

  Result = Data.define(:category) do
    def healthy?
      category == "healthy"
    end
  end

  class AuthorizationError < StandardError; end
  class RequestError < StandardError; end
  class SchemaError < StandardError; end

  class HerokuClient
    PLATFORM_HOST = "api.heroku.com"
    DATA_HOST = "api.data.heroku.com"
    PLATFORM_ACCEPT = "application/vnd.heroku+json; version=3"
    DATA_ACCEPT = "application/json"
    MAX_RETRIES = 1
    RETRY_DELAY = 0.25

    class TransientRequestError < StandardError; end

    TRANSIENT_ERRORS = [
      TransientRequestError,
      Timeout::Error,
      SocketError,
      EOFError,
      IOError,
      SystemCallError,
      Net::HTTPBadResponse,
      Net::ProtocolError,
      OpenSSL::SSL::SSLError
    ].freeze

    def initialize(token:, app:, open_timeout: 10, read_timeout: 20, retry_delay: RETRY_DELAY, sleeper: Kernel)
      @token = token
      @app = app
      @open_timeout = open_timeout
      @read_timeout = read_timeout
      @retry_delay = retry_delay
      @sleeper = sleeper
    end

    def database_attachment
      get_json(
        host: PLATFORM_HOST,
        path: "/apps/#{escape(@app)}/addon-attachments/DATABASE",
        accept: PLATFORM_ACCEPT,
        not_found: nil
      )
    end

    def transfer_schedules(addon_id)
      get_json(
        host: DATA_HOST,
        path: "/client/v11/databases/#{escape(addon_id)}/transfer-schedules",
        accept: DATA_ACCEPT
      )
    end

    def transfers
      get_json(
        host: DATA_HOST,
        path: "/client/v11/apps/#{escape(@app)}/transfers",
        accept: DATA_ACCEPT
      )
    end

    def transfer_detail(number)
      get_json(
        host: DATA_HOST,
        path: "/client/v11/apps/#{escape(@app)}/transfers/#{escape(number)}?verbose=true",
        accept: DATA_ACCEPT
      )
    end

    private

    def get_json(host:, path:, accept:, not_found: :raise)
      attempts = 0

      begin
        response = request(host:, path:, accept:)
        status = response.code.to_i

        raise AuthorizationError if status == 401 || status == 403
        raise TransientRequestError if status == 429 || status.between?(500, 599)
        return not_found if status == 404 && not_found != :raise
        raise RequestError unless status.between?(200, 299)

        JSON.parse(response.body)
      rescue *TRANSIENT_ERRORS
        attempts += 1
        raise RequestError if attempts > MAX_RETRIES

        @sleeper.sleep(@retry_delay)
        retry
      end
    rescue JSON::ParserError, TypeError
      raise SchemaError
    rescue AuthorizationError, RequestError, SchemaError
      raise
    rescue StandardError
      raise RequestError
    end

    def request(host:, path:, accept:)
      http = Net::HTTP.new(host, 443, nil)
      http.use_ssl = true
      http.open_timeout = @open_timeout
      http.read_timeout = @read_timeout

      request = Net::HTTP::Get.new(path)
      request["Accept"] = accept
      request["Authorization"] = "Bearer #{@token}"
      request["User-Agent"] = "Boat-Binder-Managed-Backup-Monitor"
      http.request(request)
    end

    def escape(value)
      URI.encode_www_form_component(value.to_s)
    end
  end

  class Monitor
    def initialize(client:, now: Time.now.utc, freshness_threshold: FRESHNESS_THRESHOLD)
      @client = client
      @now = now.utc
      @freshness_threshold = freshness_threshold
    end

    def run
      addon_id = resolve_database
      return addon_id if addon_id.is_a?(Result)

      schedule_id = resolve_schedule(addon_id)
      return schedule_id if schedule_id.is_a?(Result)

      candidates = scheduled_candidates(schedule_id)
      return candidates if candidates.is_a?(Result)

      evaluate_candidates(candidates, schedule_id)
    rescue AuthorizationError
      Result.new(category: "authorization_failed")
    rescue SchemaError
      Result.new(category: "schema_error")
    rescue RequestError, StandardError
      Result.new(category: "check_error")
    end

    private

    def resolve_database
      attachment = @client.database_attachment
      return Result.new(category: "database_resolution_failed") if attachment.nil?
      raise SchemaError unless attachment.is_a?(Hash)

      addon = attachment["addon"]
      raise SchemaError unless addon.is_a?(Hash)

      addon_id = addon["id"]
      raise SchemaError unless present_string?(addon_id)

      addon_id
    end

    def resolve_schedule(addon_id)
      schedules = @client.transfer_schedules(addon_id)
      raise SchemaError unless schedules.is_a?(Array)

      return Result.new(category: "schedule_missing") if schedules.empty?
      return Result.new(category: "schedule_ambiguous") unless schedules.one?

      schedule = schedules.first
      raise SchemaError unless schedule.is_a?(Hash)

      schedule_id = schedule["uuid"]
      raise SchemaError unless present_string?(schedule_id)

      schedule_id
    end

    def scheduled_candidates(schedule_id)
      transfers = @client.transfers
      raise SchemaError unless transfers.is_a?(Array) && transfers.all? { |entry| entry.is_a?(Hash) }

      candidates = transfers.filter_map do |transfer|
        next unless transfer.dig("schedule", "uuid") == schedule_id

        from_type = transfer["from_type"]
        to_type = transfer["to_type"]
        raise SchemaError unless present_string?(from_type) && present_string?(to_type)
        next unless from_type == "pg_dump" && to_type == "gof3r"

        number = transfer["num"]
        created_at = parse_time(transfer["created_at"])
        raise SchemaError if number.nil? || created_at.nil?

        [ created_at, number ]
      end

      return Result.new(category: "freshness_stale") if candidates.empty?

      candidates.sort_by(&:first).reverse.first(DETAIL_REQUEST_LIMIT)
    end

    def evaluate_candidates(candidates, schedule_id)
      candidates.each do |(_created_at, number)|
        detail = @client.transfer_detail(number)
        state, finished_at = transfer_state(detail, schedule_id)

        next if state == :running
        return Result.new(category: "scheduled_capture_failed") if state == :failed

        return freshness_result(finished_at)
      end

      Result.new(category: "freshness_stale")
    end

    def transfer_state(detail, schedule_id)
      raise SchemaError unless detail.is_a?(Hash)
      raise SchemaError unless detail.dig("schedule", "uuid") == schedule_id
      raise SchemaError unless detail["from_type"] == "pg_dump" && detail["to_type"] == "gof3r"
      raise SchemaError unless detail.key?("succeeded")

      succeeded = detail["succeeded"]
      raise SchemaError unless [ true, false, nil ].include?(succeeded)

      finished_value = detail["finished_at"]
      canceled_value = detail["canceled_at"]
      finished = !finished_value.nil?
      canceled = !canceled_value.nil?

      unless finished || canceled
        raise SchemaError if succeeded

        return [ :running, nil ]
      end

      finished_at = parse_time(finished_value) if finished
      canceled_at = parse_time(canceled_value) if canceled
      raise SchemaError if (finished && finished_at.nil?) || (canceled && canceled_at.nil?)

      if succeeded
        raise SchemaError if canceled || !finished

        [ :succeeded, finished_at ]
      elsif succeeded == false
        [ :failed, nil ]
      else
        raise SchemaError
      end
    end

    def freshness_result(finished_at)
      age = @now - finished_at
      raise SchemaError if age < -CLOCK_SKEW_TOLERANCE

      age = 0 if age.negative?

      category = age <= @freshness_threshold ? "healthy" : "freshness_stale"
      Result.new(category:)
    end

    def parse_time(value)
      Time.iso8601(value).utc if present_string?(value)
    rescue ArgumentError
      parse_alternate_time(value)
    end

    def parse_alternate_time(value)
      return unless value.match?(ALTERNATE_TIMESTAMP_PATTERN)

      Time.strptime(value, ALTERNATE_TIMESTAMP_FORMAT).utc
    rescue ArgumentError
      nil
    end

    def present_string?(value)
      value.is_a?(String) && !value.empty?
    end
  end

  class CLI
    def self.run(env: ENV, output: $stdout, client: nil, now: Time.now.utc)
      token = env[TOKEN_ENV].to_s
      app = env[APP_ENV].to_s
      return write_result(output, "check_error") if token.empty? || app.empty?

      client ||= HerokuClient.new(token:, app:)
      result = Monitor.new(client:, now:).run
      write_result(output, result.category)
    rescue StandardError
      write_result(output, "check_error")
    end

    def self.write_result(output, category)
      output.puts("managed_backup_monitor result=#{category}")
      category == "healthy" ? 0 : 1
    end

    private_class_method :write_result
  end
end
