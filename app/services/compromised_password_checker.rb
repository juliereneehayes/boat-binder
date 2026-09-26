require "digest/sha1"
require "net/http"
require "openssl"

class CompromisedPasswordChecker
  API_HOST = "api.pwnedpasswords.com"
  USER_AGENT = "BoatBinder-Password-Security"
  OPEN_TIMEOUT = 2
  READ_TIMEOUT = 3

  class AvailabilityError < StandardError
    attr_reader :failure_class, :status_class

    def initialize(message = nil, failure_class: nil, status_class: nil)
      @failure_class = failure_class
      @status_class = status_class
      super(message)
    end
  end

  class RangeClient
    EXPECTED_TRANSPORT_ERRORS = [
      Timeout::Error,
      SocketError,
      EOFError,
      IOError,
      SystemCallError,
      Net::HTTPBadResponse,
      Net::ProtocolError,
      OpenSSL::SSL::SSLError
    ].freeze

    def initialize(http: Net::HTTP)
      @http = http
    end

    def fetch(prefix)
      request = Net::HTTP::Get.new("/range/#{prefix}")
      request["User-Agent"] = USER_AGENT

      response = @http.start(
        API_HOST,
        443,
        use_ssl: true,
        open_timeout: OPEN_TIMEOUT,
        read_timeout: READ_TIMEOUT
      ) { |connection| connection.request(request) }

      unless response.is_a?(Net::HTTPSuccess)
        status_class = "#{response.code.to_i / 100}xx"
        raise AvailabilityError.new("Unexpected HTTP response", failure_class: "HttpResponse", status_class:)
      end

      response.body.to_s
    rescue *EXPECTED_TRANSPORT_ERRORS => error
      raise AvailabilityError.new("Transport failure", failure_class: error.class.name)
    end
  end

  def self.call(password, client: RangeClient.new, logger: Rails.logger)
    new(client:, logger:).call(password)
  end

  def initialize(client: RangeClient.new, logger: Rails.logger)
    @client = client
    @logger = logger
  end

  def call(password)
    # HIBP's Pwned Passwords range protocol mandates SHA-1 for this lookup. It is
    # not used for password storage or authentication (User uses bcrypt via
    # has_secure_password), and only the first five hexadecimal characters leave
    # the server; the remaining suffix is compared locally.
    digest = Digest::SHA1.hexdigest(password).upcase
    prefix = digest.first(5)
    suffix = digest.delete_prefix(prefix)

    compromised_suffixes(@client.fetch(prefix)).include?(suffix)
  rescue AvailabilityError => error
    details = [ "error_class=#{error.class.name}" ]
    details << "failure_class=#{error.failure_class}" if error.failure_class
    details << "status_class=#{error.status_class}" if error.status_class
    @logger.warn("Compromised password check unavailable #{details.join(" ")}")
    false
  end

  private

  def compromised_suffixes(body)
    lines = body.lines(chomp: true).map { |line| line.delete_suffix("\r") }
    unless lines.any? && lines.all? { |line| line.match?(/\A[0-9A-Fa-f]{35}:\d+\z/) }
      raise AvailabilityError.new("Unusable range response", failure_class: "MalformedResponse")
    end

    lines.map { |line| line.split(":", 2).first.upcase }
  end
end
