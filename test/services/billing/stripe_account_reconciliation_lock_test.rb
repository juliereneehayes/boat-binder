require "test_helper"
require "timeout"

module Billing
  class StripeAccountReconciliationLockTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    test "same Account lock times out while another connection holds it" do
      account = create_account(name: "Advisory Lock Same Account")
      lock_acquired = Queue.new
      release_lock = Queue.new
      holder = hold_lock(account.id, lock_acquired:, release_lock:)
      Timeout.timeout(5) { lock_acquired.pop }

      error = assert_raises(StripeAccountReconciliationLock::LockTimeoutError) do
        StripeAccountReconciliationLock.call(account_id: account.id, timeout: 0) { flunk("lock must not overlap") }
      end
      assert_equal "Stripe account reconciliation is already in progress", error.message
    ensure
      release_lock&.push(true)
      holder&.join(5)
      account&.destroy!
    end

    test "different Account locks can run concurrently" do
      first_account = create_account(name: "Advisory Lock First Account")
      second_account = create_account(name: "Advisory Lock Second Account")
      lock_acquired = Queue.new
      release_lock = Queue.new
      holder = hold_lock(first_account.id, lock_acquired:, release_lock:)
      Timeout.timeout(5) { lock_acquired.pop }

      entered = false
      StripeAccountReconciliationLock.call(account_id: second_account.id, timeout: 0) { entered = true }

      assert entered
    ensure
      release_lock&.push(true)
      holder&.join(5)
      first_account&.destroy!
      second_account&.destroy!
    end

    test "lock is released after an exception without leaking into the connection pool" do
      account = create_account(name: "Advisory Lock Exception Release")
      failure_observed = Queue.new
      release_connection = Queue.new
      worker = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          StripeAccountReconciliationLock.call(account_id: account.id) { raise "controlled failure" }
        rescue RuntimeError
          failure_observed << true
          release_connection.pop
        end
      end
      Timeout.timeout(5) { failure_observed.pop }

      entered = false
      StripeAccountReconciliationLock.call(account_id: account.id, timeout: 0) { entered = true }

      assert entered
    ensure
      release_connection&.push(true)
      worker&.join(5)
      account&.destroy!
    end

    test "nested same Account locks balance their session acquisitions" do
      account = create_account(name: "Advisory Lock Reentrant")

      StripeAccountReconciliationLock.call(account_id: account.id) do
        StripeAccountReconciliationLock.call(account_id: account.id) { assert true }

        contender = Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            StripeAccountReconciliationLock.call(account_id: account.id, timeout: 0) { flunk("outer lock remains held") }
          end
        rescue StripeAccountReconciliationLock::LockTimeoutError
          :timed_out
        end
        assert_equal :timed_out, contender.value
      end

      assert_nothing_raised do
        StripeAccountReconciliationLock.call(account_id: account.id, timeout: 0) { true }
      end
    ensure
      account&.destroy!
    end

    private

    def hold_lock(account_id, lock_acquired:, release_lock:)
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          StripeAccountReconciliationLock.call(account_id:) do
            lock_acquired << true
            release_lock.pop
          end
        end
      end
    end
  end
end
