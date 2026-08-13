module Billing
  class StripeCheckoutAccountResolver
    class ResolutionError < StandardError; end

    def self.call(user)
      new(user).call
    end

    def initialize(user)
      @user = user
    end

    def call
      raise ResolutionError, "An eligible owner account could not be determined" unless user&.owner? && user.active?

      accounts = eligible_accounts.limit(2).to_a
      return accounts.first if accounts.one?

      raise ResolutionError, "An eligible owner account could not be determined"
    end

    private

    attr_reader :user

    def eligible_accounts
      Account.active.client
        .joins(:account_memberships)
        .where(account_memberships: {
          user_id: user.id,
          active: true,
          access_level: "editor"
        })
        .distinct
    end
  end
end
