require "digest"

module Billing
  class StripeAccountReconciliationLock
    NAMESPACE = "boat_binder:stripe_account_reconciliation:v1"
    DEFAULT_TIMEOUT = 5.seconds
    POLL_INTERVAL = 0.05.seconds

    class LockTimeoutError < StandardError; end
    class LockReleaseError < StandardError; end

    def self.call(account_id:, timeout: DEFAULT_TIMEOUT, &block)
      new(account_id:, timeout:).call(&block)
    end

    def initialize(account_id:, timeout:, clock: Process.method(:clock_gettime), sleeper: Kernel.method(:sleep))
      @account_id = Integer(account_id)
      @timeout = Float(timeout)
      @clock = clock
      @sleeper = sleeper
    end

    def call
      held_locks = ActiveSupport::IsolatedExecutionState[:stripe_account_reconciliation_locks] ||= {}
      return yield if held_locks[lock_key]

      ActiveRecord::Base.connection_pool.with_connection do |connection|
        acquire!(connection)
        held_locks[lock_key] = true

        begin
          yield
        ensure
          begin
            release!(connection)
          ensure
            held_locks.delete(lock_key)
          end
        end
      end
    end

    private

    attr_reader :account_id, :clock, :sleeper, :timeout

    def acquire!(connection)
      deadline = monotonic_time + timeout

      loop do
        return if advisory_query(connection, "pg_try_advisory_lock")

        remaining = deadline - monotonic_time
        raise LockTimeoutError, "Stripe account reconciliation is already in progress" if remaining <= 0

        sleeper.call([ POLL_INTERVAL, remaining ].min)
      end
    end

    def release!(connection)
      return if advisory_query(connection, "pg_advisory_unlock")

      connection.disconnect!
      raise LockReleaseError, "Stripe account reconciliation lock could not be released"
    rescue LockReleaseError
      raise
    rescue StandardError
      connection.disconnect!
      raise LockReleaseError, "Stripe account reconciliation lock could not be released"
    end

    def advisory_query(connection, function)
      connection.select_value("SELECT #{function}(#{connection.quote(lock_key)})") == true
    end

    def lock_key
      @lock_key ||= Digest::SHA256.digest("#{NAMESPACE}:#{account_id}").unpack1("q>")
    end

    def monotonic_time
      clock.call(Process::CLOCK_MONOTONIC)
    end
  end
end
