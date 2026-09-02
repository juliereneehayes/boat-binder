require "test_helper"
require "timeout"

module Billing
  class OwnerUserLimitTest < ActiveSupport::TestCase
    self.use_transactional_tests = false

    setup do
      @records = []
      @account = remember(create_account(name: "Owner Limit #{SecureRandom.hex(6)}"))
      qualify_self_managed_subscription(@account)
    end

    teardown do
      @records.reverse_each do |record|
        record.class.where(id: record.id).destroy_all if record&.persisted?
      end
    end

    test "Self Managed counts active read only and editor Owner memberships" do
      editor = remember(create_user(email: unique_email("editor"), role: "owner"))
      read_only = remember(create_user(email: unique_email("read-only"), role: "owner"))
      second_editor = remember(create_user(email: unique_email("second-editor"), role: "owner"))
      inactive = remember(create_user(email: unique_email("inactive"), role: "owner"))

      remember(create_account_membership(user: editor, account: @account, access_level: "editor"))
      blocked = AccountMembership.new(user: read_only, account: @account, access_level: "read_only")
      blocked_editor = AccountMembership.new(user: second_editor, account: @account, access_level: "editor")
      inactive_membership = remember(create_account_membership(
        user: inactive,
        account: @account,
        access_level: "editor",
        active: false
      ))

      assert_not blocked.save
      assert_includes blocked.errors.full_messages, OwnerUserLimit::ERROR_MESSAGE
      assert_not blocked_editor.save
      assert_includes blocked_editor.errors.full_messages, OwnerUserLimit::ERROR_MESSAGE
      assert inactive_membership.persisted?
      assert OwnerUserLimit.compliant?(@account)
    end

    test "reactivation is rejected while occupied and succeeds after deactivation" do
      current = remember(create_user(email: unique_email("current"), role: "owner"))
      replacement = remember(create_user(email: unique_email("replacement"), role: "owner"))
      current_membership = remember(create_account_membership(user: current, account: @account))
      replacement_membership = remember(create_account_membership(
        user: replacement,
        account: @account,
        active: false
      ))

      replacement_membership.active = true
      assert_not replacement_membership.save
      assert_includes replacement_membership.errors.full_messages, OwnerUserLimit::ERROR_MESSAGE

      current_membership.update!(active: false)
      assert replacement_membership.save
      assert_equal 1, OwnerUserLimit.active_owner_count(@account)
    end

    test "changing the current user to a non Owner role frees the seat" do
      current = remember(create_user(email: unique_email("role-current"), role: "owner"))
      replacement = remember(create_user(email: unique_email("role-replacement"), role: "owner"))
      current_membership = remember(create_account_membership(user: current, account: @account))
      replacement_membership = remember(create_account_membership(
        user: replacement,
        account: @account,
        active: false
      ))

      current.update!(role: "captain")
      replacement_membership.update!(active: true)

      assert current_membership.reload.active?
      committed_owner_count = AccountMembership.uncached do
        OwnerUserLimit.active_owner_count(Account.find(@account.id))
      end
      assert_equal 1, committed_owner_count
      assert_equal replacement, @account.owner_user_memberships.active.sole.user
    end

    test "ordinary updates to the sole active Owner membership still succeed" do
      owner = remember(create_user(email: unique_email("sole-update"), role: "owner"))
      membership = remember(create_account_membership(user: owner, account: @account, access_level: "read_only"))

      membership.update!(access_level: "editor")

      assert_equal "editor", membership.reload.access_level
      assert OwnerUserLimit.compliant?(@account)
    end

    test "non Self Managed plans do not apply the Self Managed seat limit" do
      @account.subscription.update!(plan: "legacy", provider: "local")
      first = remember(create_user(email: unique_email("legacy-first"), role: "owner"))
      second = remember(create_user(email: unique_email("legacy-second"), role: "owner"))

      remember(create_account_membership(user: first, account: @account))
      second_membership = remember(create_account_membership(user: second, account: @account))

      assert second_membership.persisted?
      assert OwnerUserLimit.compliant?(@account)
      assert_not OwnerUserLimit.compliant_for_plan?(
        @account,
        plan_key: SubscriptionPlanCatalog::SELF_MANAGED_PLAN_KEY
      )
    end

    test "ordinary concurrent membership saves hold the validation lock through the insert" do
      first = remember(create_user(email: unique_email("concurrent-first"), role: "owner"))
      second = remember(create_user(email: unique_email("concurrent-second"), role: "owner"))
      first_validated = Queue.new
      release_first_validation = Queue.new
      second_started = Queue.new
      results = Queue.new
      pause_after_validation = lambda do
        queues = Thread.current[:owner_limit_validation_pause]
        next unless queues

        queues.fetch(:validated) << true
        queues.fetch(:release).pop
      end
      AccountMembership.set_callback(:validation, :after, pause_after_validation)

      first_thread = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Thread.current[:owner_limit_validation_pause] = {
            validated: first_validated,
            release: release_first_validation
          }
          results << AccountMembership.create(user: first, account_id: @account.id)
        end
      rescue StandardError => error
        results << error
      ensure
        Thread.current[:owner_limit_validation_pause] = nil
      end
      Timeout.timeout(5) { first_validated.pop }

      second_thread = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          second_started << true
          results << AccountMembership.create(user: second, account: Account.find(@account.id))
        end
      rescue StandardError => error
        results << error
      end
      Timeout.timeout(5) { second_started.pop }
      Timeout.timeout(5) do
        Thread.pass until second_thread.status == "sleep"
      end

      assert first_thread.alive?, "first save must still be paused before its INSERT"
      assert second_thread.alive?, "second save must wait for the first validation lock"
      assert_equal 0, OwnerUserLimit.active_owner_count(@account)

      release_first_validation << true
      assert first_thread.join(5), "first Owner membership write deadlocked"
      assert second_thread.join(5), "second Owner membership write deadlocked"

      memberships = 2.times.map { Timeout.timeout(5) { results.pop } }
      memberships.each { |membership| assert_instance_of AccountMembership, membership }
      memberships.each { |membership| remember(membership) }
      assert_equal 1, memberships.count(&:persisted?)
      persisted = memberships.find(&:persisted?).reload
      assert_equal @account.id, persisted.account_id
      assert persisted.active?
      assert persisted.user.owner?
      rejected = memberships.reject(&:persisted?).sole
      assert_includes rejected.errors.full_messages, OwnerUserLimit::ERROR_MESSAGE
    ensure
      release_first_validation << true if first_thread&.alive?
      first_thread&.join(1)
      second_thread&.join(1)
      AccountMembership.skip_callback(:validation, :after, pause_after_validation) if pause_after_validation
    end

    test "audit reports minimized identifiers for existing violations" do
      first = remember(create_user(email: unique_email("audit-first"), role: "owner"))
      second = remember(create_user(email: unique_email("audit-second"), role: "owner"))
      insert_membership(first)
      insert_membership(second)

      violation = OwnerUserLimit.violations.find { |candidate| candidate.account_id == @account.id }

      assert violation
      assert_equal 2, violation.active_owner_count
      assert_equal 1, violation.limit
      assert_equal %i[account_id active_owner_count limit], violation.to_h.keys
    end

    private

    def remember(record)
      @records << record
      record
    end

    def unique_email(prefix)
      "#{prefix}-#{SecureRandom.hex(6)}@example.test"
    end

    def insert_membership(user)
      now = Time.current
      AccountMembership.insert_all!([ {
        account_id: @account.id,
        user_id: user.id,
        access_level: "editor",
        active: true,
        created_at: now,
        updated_at: now
      } ])
    end
  end
end
