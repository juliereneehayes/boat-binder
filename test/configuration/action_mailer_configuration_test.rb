require "test_helper"

class ActionMailerConfigurationTest < ActiveSupport::TestCase
  test "production SMTP uses bounded connection and read timeouts" do
    production_source = Rails.root.join("config/environments/production.rb").read

    assert_includes production_source, "open_timeout: 5"
    assert_includes production_source, "read_timeout: 10"

    smtp = Mail::SMTP.new(open_timeout: 5, read_timeout: 10)
    assert_equal 5, smtp.settings[:open_timeout]
    assert_equal 10, smtp.settings[:read_timeout]
  end
end
