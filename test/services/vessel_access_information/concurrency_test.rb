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
end
