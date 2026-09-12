class DatabaseSeedSafety
  class ProhibitedEnvironmentError < StandardError; end

  def self.ensure_allowed!(environment: Rails.env)
    return unless environment.production?

    raise ProhibitedEnvironmentError,
      "Production database seeding is prohibited. Use a narrowly scoped operational procedure instead."
  end
end
