require "test_helper"
require "stringio"

class CompromisedPasswordCheckerTest < ActiveSupport::TestCase
  class RecordingClient
    attr_reader :prefixes

    def initialize(body)
      @body = body
      @prefixes = []
    end

    def fetch(prefix)
      @prefixes << prefix
      @body
    end
  end

  class FakeHttp
    attr_reader :host, :port, :options, :received_request

    def initialize(response: nil, error: nil)
      @response = response
      @error = error
    end

    def start(host, port, **options)
      @host = host
      @port = port
      @options = options
      raise @error if @error

      yield self
    end

    def request(request)
      @received_request = request
      @response
    end
  end

  test "matching suffix is compromised and only the five-character prefix is disclosed" do
    password = "a private password phrase"
    # Fixed SHA-1 fixture for HIBP's protocol; application passwords remain bcrypt-backed.
    digest = "7EE73412C7C7AA6CB9636C786BAC5660782E602D"
    client = RecordingClient.new("#{digest.last(35)}:42\r\n#{"A" * 35}:1\r\n")

    assert CompromisedPasswordChecker.call(password, client:)
    assert_equal [ digest.first(5) ], client.prefixes
    assert_not_includes client.prefixes, password
    assert_not_includes client.prefixes, digest
  end

  test "nonmatching and lowercase suffixes are handled locally" do
    password = "another private password phrase"
    # Fixed SHA-1 fixture for HIBP's protocol; application passwords remain bcrypt-backed.
    digest = "469A7C093E03AE2DCCBF4E4C9675C17F7AB3344B"
    nonmatch = RecordingClient.new("#{"B" * 35}:3\n")
    lowercase_match = RecordingClient.new("#{digest.last(35).downcase}:3\n")

    assert_not CompromisedPasswordChecker.call(password, client: nonmatch)
    assert CompromisedPasswordChecker.call(password, client: lowercase_match)
  end

  test "range client sets the endpoint, identifying user agent, TLS, and short timeouts" do
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.instance_variable_set(:@body, "#{"A" * 35}:1\n")
    response.instance_variable_set(:@read, true)
    http = FakeHttp.new(response:)

    body = CompromisedPasswordChecker::RangeClient.new(http:).fetch("ABCDE")

    assert_equal response.body, body
    assert_equal CompromisedPasswordChecker::API_HOST, http.host
    assert_equal 443, http.port
    assert_equal "/range/ABCDE", http.received_request.path
    assert_equal CompromisedPasswordChecker::USER_AGENT, http.received_request["User-Agent"]
    assert_equal true, http.options[:use_ssl]
    assert_equal CompromisedPasswordChecker::OPEN_TIMEOUT, http.options[:open_timeout]
    assert_equal CompromisedPasswordChecker::READ_TIMEOUT, http.options[:read_timeout]
  end

  test "connection and read timeouts are availability failures and fail open" do
    [ Net::OpenTimeout, Net::ReadTimeout ].each do |error_class|
      logger_output = StringIO.new
      logger = ActiveSupport::Logger.new(logger_output)
      http = FakeHttp.new(error: error_class.new("secret transport details"))
      client = CompromisedPasswordChecker::RangeClient.new(http:)

      assert_not CompromisedPasswordChecker.call("timeout password phrase", client:, logger:)
      assert_includes logger_output.string, "CompromisedPasswordChecker::AvailabilityError"
      assert_includes logger_output.string, "failure_class=#{error_class.name}"
      assert_not_includes logger_output.string, "secret transport details"
    end
  end

  test "HTTP failures and malformed responses fail open with minimized warnings" do
    failure = Net::HTTPServiceUnavailable.new("1.1", "503", "Unavailable")
    failure.instance_variable_set(:@body, "upstream secret")
    failure.instance_variable_set(:@read, true)
    logger_output = StringIO.new
    logger = ActiveSupport::Logger.new(logger_output)
    client = CompromisedPasswordChecker::RangeClient.new(http: FakeHttp.new(response: failure))

    assert_not CompromisedPasswordChecker.call("http failure password", client:, logger:)
    assert_includes logger_output.string, "status_class=5xx"
    assert_not_includes logger_output.string, "upstream secret"

    logger_output.truncate(0)
    malformed = RecordingClient.new("not a usable range response")
    assert_not CompromisedPasswordChecker.call("malformed response password", client: malformed, logger:)
    assert_includes logger_output.string, "failure_class=MalformedResponse"
  end

  test "programming errors are not swallowed" do
    client = Object.new
    client.define_singleton_method(:fetch) { |_prefix| raise NoMethodError, "implementation defect" }

    assert_raises(NoMethodError) do
      CompromisedPasswordChecker.call("valid local password", client:)
    end
  end
end
