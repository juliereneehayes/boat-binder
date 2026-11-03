module PublicAnalytics
  class Configuration
    MARKETING_HOSTS = %w[boat-binder.com www.boat-binder.com].freeze
    MEASUREMENT_ID_FORMAT = /\AG-[A-Z0-9]+\z/

    class << self
      def measurement_id(
        host:,
        environment: Rails.env,
        configured_measurement_id: Rails.configuration.x.google_analytics.measurement_id
      )
        measurement_id = configured_measurement_id.to_s.strip

        return unless environment.to_s == "production"
        return unless MARKETING_HOSTS.include?(host)
        return unless MEASUREMENT_ID_FORMAT.match?(measurement_id)

        measurement_id
      end
    end
  end
end
