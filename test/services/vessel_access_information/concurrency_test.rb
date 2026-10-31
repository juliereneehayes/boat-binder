require "test_helper"
require "timeout"

class VesselAccessInformation::ConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    suffix = SecureRandom.hex(6)
    @account = create_account(name: "Concurrent Vessel Access #{suffix}")
    @relationship = @account.create_managed_service_relationship!(active: true)
    @vessel = create_vessel(account: @account, name: "Concurrent Vessel #{suffix}")
    @actor = create_user(email: "concurrent-vessel-access-#{suffix}@example.test", role: "admin")
    @request_prefix = "vessel-access-concurrency-#{suffix}"
  end

  teardown do
    SecurityAuditEvent.connection.execute(
      SecurityAuditEvent.sanitize_sql_array(
        [ "DELETE FROM security_audit_events WHERE request_id LIKE ?", "#{@request_prefix}%" ]
      )
    )
    VesselAccessInformation.where(asset_id: @vessel.id).delete_all
    @relationship.destroy!
    @vessel.destroy!
    @account.reload.destroy!
    @actor.destroy!
  end

  test "simultaneous first writes serialize onto one encrypted Vessel record" do
    start = Queue.new
    results = Queue.new

    threads = 2.times.map do |index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          start.pop
          record = VesselAccessInformation::Persistence.save!(
            vessel: Asset.find(@vessel.id),
            restricted_details: "Synthetic concurrent value #{index}",
            actor: User.find(@actor.id),
            request_id: "#{@request_prefix}-#{index}"
          )
          results << record.id
        rescue StandardError => error
          results << error
        end
      end
    end

    2.times { start << true }
    threads.each { |thread| assert thread.join(5), "concurrent restricted write deadlocked" }
    outcomes = 2.times.map { Timeout.timeout(5) { results.pop } }

    outcomes.each { |outcome| assert_kind_of Integer, outcome }
    assert_equal 1, outcomes.uniq.length
    assert_equal 1, VesselAccessInformation.where(asset_id: @vessel.id).count
    assert_includes [ "Synthetic concurrent value 0", "Synthetic concurrent value 1" ],
      VesselAccessInformation.find(outcomes.first).restricted_details
    assert_equal [
      "vessel_access_information.created",
      "vessel_access_information.updated"
    ], SecurityAuditEvent.where(request_id: [
      "#{@request_prefix}-0",
      "#{@request_prefix}-1"
    ]).order(:id).pluck(:action)
  ensure
    2.times { start << true }
    threads&.each { |thread| thread.join(1) }
  end

  test "concurrent partial field writes preserve both independently updated values" do
    start = Queue.new
    results = Queue.new
    updates = [
      [ "marina_gate_code", "Synthetic concurrent gate 2401" ],
      [ "lockbox_code", "Synthetic concurrent lockbox 8407" ]
    ]

    threads = updates.each_with_index.map do |(field, value), index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          start.pop
          record = VesselAccessInformation::Persistence.update_fields!(
            vessel: Asset.find(@vessel.id),
            updates: { field => { operation: "replace", value: } },
            actor: User.find(@actor.id),
            request_id: "#{@request_prefix}-partial-#{index}"
          )
          results << record.id
        rescue StandardError => error
          results << error
        end
      end
    end

    2.times { start << true }
    threads.each { |thread| assert thread.join(5), "concurrent partial write deadlocked" }
    outcomes = 2.times.map { Timeout.timeout(5) { results.pop } }

    outcomes.each { |outcome| assert_kind_of Integer, outcome }
    assert_equal 1, outcomes.uniq.length
    record = VesselAccessInformation.find(outcomes.first)
    assert_equal "Synthetic concurrent gate 2401", record.restricted_field("marina_gate_code")
    assert_equal "Synthetic concurrent lockbox 8407", record.restricted_field("lockbox_code")
  ensure
    2.times { start << true }
    threads&.each { |thread| thread.join(1) }
  end


  test "credential creation and account reassignment serialize on the Vessel boundary" do
    target_account = create_account(name: "Concurrent Reassignment Target #{SecureRandom.hex(4)}")
    lock_acquired = Queue.new
    release_lock = Queue.new
    reassignment_started = Queue.new
    results = Queue.new

    writer = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Asset.find(@vessel.id).with_lock do
          lock_acquired << true
          release_lock.pop
          record = VesselAccessInformation::Persistence.save!(
            vessel: Asset.find(@vessel.id),
            restricted_details: "Synthetic concurrent reassignment credential",
            actor: User.find(@actor.id),
            request_id: "#{@request_prefix}-reassignment-write"
          )
          results << [ :write, record.id ]
        end
      rescue StandardError => error
        results << [ :write_error, error ]
      end
    end

    Timeout.timeout(5) { lock_acquired.pop }
    reassigner = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        vessel = Asset.find(@vessel.id)
        reassignment_started << true
        results << [ :reassignment, vessel.update(account: target_account), vessel.errors.full_messages ]
      rescue StandardError => error
        results << [ :reassignment_error, error ]
      end
    end

    Timeout.timeout(5) { reassignment_started.pop }
    release_lock << true
    assert writer.join(5), "restricted write deadlocked"
    assert reassigner.join(5), "account reassignment deadlocked"
    outcomes = 2.times.map { Timeout.timeout(5) { results.pop } }.index_by(&:first)

    assert_kind_of Integer, outcomes.fetch(:write).second
    assert_equal false, outcomes.fetch(:reassignment).second
    assert_includes outcomes.fetch(:reassignment).third,
      "Account cannot be changed while restricted access information is retained"
    assert_equal @account, @vessel.reload.account
    assert_equal @vessel.id, VesselAccessInformation.find(outcomes.fetch(:write).second).asset_id
  ensure
    release_lock << true if release_lock
    writer&.join(1)
    reassigner&.join(1)
    target_account&.destroy!
  end
end
