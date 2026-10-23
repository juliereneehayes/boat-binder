require "test_helper"

class ActiveStorageConfigurationTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

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

  test "disables content analyzers and previewers until scan-approved processing exists" do
    assert_empty Rails.application.config.active_storage.analyzers
    assert_empty Rails.application.config.active_storage.previewers
    assert_empty ActiveStorage.analyzers
    assert_empty ActiveStorage.previewers

    account = create_account(name: "No Analyzer Account")
    document = Document.create!(account:, title: "No analyzer", document_type: "other")

    assert_no_enqueued_jobs only: ActiveStorage::AnalyzeJob do
      file_fixture("sample.jpg").open do |file|
        document.file.attach(io: file, filename: "sample.jpg", content_type: "image/jpeg")
      end
    end
  end
end
