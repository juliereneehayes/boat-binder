ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Add more helper methods to be used by all tests here...
    def create_account(name: "Hayes Yacht Company", account_type: "client", time_zone: Account::DEFAULT_TIME_ZONE)
      creator = AccountCreator.call(
        account_attributes: {
          name: name,
          account_type: account_type,
          time_zone: time_zone
        }
      )
      raise ActiveRecord::RecordInvalid, creator.account unless creator.success?

      creator.account
    end

    def create_user(email: "captain@example.test", role: "captain", name: nil, active: true)
      User.create!(
        name: name,
        email_address: email,
        password: "password",
        password_confirmation: "password",
        role: role,
        active: active
      )
    end

    def create_account_membership(user:, account:, access_level: "read_only", active: true)
      AccountMembership.create!(
        user: user,
        account: account,
        access_level: access_level,
        active: active
      )
    end

    def create_asset(account: create_account, asset_type: "vessel", name: "Blue Meridian")
      Asset.create!(
        account: account,
        asset_type: asset_type,
        name: name,
        make: "Sabre",
        model: "48 Salon Express",
        year: 2020,
        length: 48,
        marina: "Bainbridge Marina",
        slip: "C-18"
      )
    end

    def create_vessel(account: create_account, name: "Blue Meridian")
      create_asset(account: account, asset_type: "vessel", name: name)
    end

    def create_battery(asset: create_vessel, name: "House Battery 1")
      AssetBattery.create!(
        asset: asset,
        name: name,
        location: "Engine room",
        battery_type: "AGM"
      )
    end

    def sign_in_as(user = create_user)
      post session_path, params: {
        email_address: user.email_address,
        password: "password"
      }
    end

    def assert_access_denied_redirect
      assert_redirected_to root_path
      follow_redirect!
      assert_includes response.body, Authorization::ACCESS_DENIED_MESSAGE
    end
  end
end
