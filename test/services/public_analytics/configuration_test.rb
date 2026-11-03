require "test_helper"

class PublicAnalytics::ConfigurationTest < ActiveSupport::TestCase
  test "returns a configured measurement ID only for approved production marketing hosts" do
    %w[boat-binder.com www.boat-binder.com].each do |host|
      assert_equal "G-TEST123", measurement_id(host:)
    end
  end

  test "does not enable analytics on staging even though staging uses the production environment" do
    assert_nil measurement_id(host: "staging.boat-binder.com")
  end

  test "does not enable analytics for application or unapproved hosts" do
    assert_nil measurement_id(host: "app.boat-binder.com")
    assert_nil measurement_id(host: "marketing.example.test")
  end

  test "does not enable analytics outside production" do
    %w[development test].each do |environment|
      assert_nil measurement_id(environment:)
    end
  end

  test "does not enable analytics when the measurement ID is missing or invalid" do
    assert_nil measurement_id(configured_measurement_id: nil)
    assert_nil measurement_id(configured_measurement_id: "")
    assert_nil measurement_id(configured_measurement_id: "not-a-measurement-id")
    assert_nil measurement_id(configured_measurement_id: "g-test123")
    assert_nil measurement_id(configured_measurement_id: "G-Test123")
    assert_nil measurement_id(configured_measurement_id: "G-TEST123\" onload=\"alert(1)")
  end

  private

  def measurement_id(
    host: "boat-binder.com",
    environment: "production",
    configured_measurement_id: "G-TEST123"
  )
    PublicAnalytics::Configuration.measurement_id(
      host:,
      environment:,
      configured_measurement_id:
    )
  end
end
