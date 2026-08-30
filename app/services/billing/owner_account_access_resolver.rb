module Billing
  class OwnerAccountAccessResolver
    Result = Data.define(:account, :membership)

    class ResolutionError < StandardError; end

    def self.call(user:, account_reference:, access_levels: AccountMembership::ACCESS_LEVELS)
      new(user:, account_reference:, access_levels:).call
    end

    def initialize(user:, account_reference:, access_levels:)
      @user = user
      @account_reference = account_reference
      @access_levels = Array(access_levels) & AccountMembership::ACCESS_LEVELS
    end

    def call
      raise ResolutionError, "An eligible owner account could not be determined" unless eligible_user?

      account = OwnerAccountReference.find!(account_reference)
      membership = user.account_memberships.active.find_by(
        account:,
        access_level: access_levels
      )
      return Result.new(account:, membership:) if membership && account.active? && account.account_type == "client"

      raise ResolutionError, "An eligible owner account could not be determined"
    rescue OwnerAccountReference::InvalidReferenceError
      raise ResolutionError, "An eligible owner account could not be determined"
    end

    private

    attr_reader :user, :account_reference, :access_levels

    def eligible_user?
      user&.owner? && user.active? && account_reference.is_a?(String) && account_reference.present? && access_levels.any?
    end
  end
end
