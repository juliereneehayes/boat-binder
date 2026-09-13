require "test_helper"

class ActiveStorageConfigurationTest < ActiveSupport::TestCase
  test "does not mount Active Storage's public application routes" do
    assert_equal false, Rails.application.config.active_storage.draw_routes

    route_paths = Rails.application.routes.routes.map { |route| route.path.spec.to_s }
    assert_empty route_paths.grep(%r{rails/active_storage})
  end

  test "uses the patched Active Storage release with supported Vips dependencies" do
    assert_operator ActiveStorage.gem_version, :>=, Gem::Version.new("8.1.3.1")
    assert_equal :vips, Rails.application.config.active_storage.variant_processor
    assert_operator Gem::Specification.find_by_name("ruby-vips").version, :>=, Gem::Version.new("2.2.1")
  end
end
