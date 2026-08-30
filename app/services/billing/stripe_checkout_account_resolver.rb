module Billing
  class StripeCheckoutAccountResolver
    class ResolutionError < StandardError; end

    def self.call(user, account_reference: nil)
      new(user, account_reference:).call
    end

    def initialize(user, account_reference: nil)
      @user = user
      @account_reference = account_reference
    end

    def call
      raise ResolutionError, "An eligible owner account could not be determined" unless user&.owner? && user.active?

      return referenced_account if account_reference

      accounts = eligible_accounts.limit(2).to_a
      return accounts.first if accounts.one?

      raise ResolutionError, "An eligible owner account could not be determined"
    end

    private

    attr_reader :user, :account_reference

    def referenced_account
      OwnerAccountAccessResolver.call(
        user:,
        account_reference:,
        access_levels: [ "editor" ]
      ).account
    rescue OwnerAccountAccessResolver::ResolutionError
      raise ResolutionError, "An eligible owner account could not be determined"
    end

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
