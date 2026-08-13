require "test_helper"

module Billing
  class StripeResourceRetrieveCompatibilityTest < ActiveSupport::TestCase
    test "Stripe resource classes inherit the two-argument retrieve API" do
      expected_parameters = [ [ :req, :id ], [ :opt, :opts ] ]
      api_resource_source = Stripe::APIResource.method(:retrieve).source_location

      [ Stripe::Subscription, Stripe::Checkout::Session ].each do |resource_class|
        retrieve_method = resource_class.method(:retrieve)

        assert_equal expected_parameters, retrieve_method.parameters
        assert_equal api_resource_source, retrieve_method.source_location
      end
    end
  end
end
