require "application_system_test_case"

class PublicAnalyticsSystemTest < ApplicationSystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1200, 900 ]

  test "sanitizes analytics payloads and prevents duplicate pageviews" do
    visit signup_path

    install_analytics_harness
    wait_for_command("page_view")

    commands = analytics_commands
    config = commands.find { |command| command.first == "config" }
    page_view = commands.find { |command| command.first == "event" && command.second == "page_view" }

    expected_location = "#{page.evaluate_script('window.location.origin')}/?utm_source=instagram&utm_medium=social&utm_campaign=launch_2026&utm_content=hero_cta"
    assert_equal expected_location, config.third.fetch("page_location")
    assert_equal expected_location, page_view.third.fetch("page_location")
    assert_equal "https://partner.example", config.third.fetch("page_referrer")
    assert_equal "https://partner.example", page_view.third.fetch("page_referrer")
    assert_equal false, config.third.fetch("allow_google_signals")
    assert_equal false, config.third.fetch("allow_ad_personalization_signals")
    assert_equal false, config.third.fetch("send_page_view")

    serialized_commands = commands.to_json
    %w[owner@example.com account_42 vessel_42 document_42 verification_token secret_fragment].each do |private_value|
      assert_not_includes serialized_commands, private_value
    end

    page.execute_script(<<~JAVASCRIPT)
      window.Stimulus.getControllerForElementAndIdentifier(document.body, "public-analytics").connect()
    JAVASCRIPT
    assert_equal 1, event_count("page_view")

    page.execute_script(<<~JAVASCRIPT)
      const controller = window.Stimulus.getControllerForElementAndIdentifier(document.body, "public-analytics")
      controller.handlePageShow({ persisted: true })
    JAVASCRIPT
    wait_for_event_count("page_view", 2)
    assert_equal 2, event_count("page_view")
    assert_equal 1, document_script_load_count
  end

  test "ordinary CTA click navigates once when the analytics callback succeeds" do
    install_navigation_harness(<<~JAVASCRIPT)
      window.gtag = (...command) => {
        if (command[0] !== "event") return

        const parameters = command[2]
        sessionStorage.setItem("analyticsEventCount", String(Number(sessionStorage.getItem("analyticsEventCount") || 0) + 1))
        sessionStorage.setItem("analyticsEventName", command[1])
        sessionStorage.setItem("analyticsEventTimeout", String(parameters.event_timeout))
        window.setTimeout(parameters.event_callback, 25)
      }
    JAVASCRIPT

    find("#analytics-test-cta").double_click

    assert_signup_navigation("callback")
    assert_equal "1", page.evaluate_script("sessionStorage.getItem('analyticsEventCount')")
    assert_equal "start_free_trial_click", page.evaluate_script("sessionStorage.getItem('analyticsEventName')")
    assert_equal "300", page.evaluate_script("sessionStorage.getItem('analyticsEventTimeout')")
  end

  test "ordinary CTA click navigates after the bounded timeout when no callback arrives" do
    install_navigation_harness(<<~JAVASCRIPT, destination: "timeout")
      window.gtag = (...command) => {
        if (command[0] !== "event") return

        sessionStorage.setItem("analyticsEventCount", String(Number(sessionStorage.getItem("analyticsEventCount") || 0) + 1))
        sessionStorage.setItem("analyticsEventName", command[1])
        sessionStorage.setItem("analyticsEventTimeout", String(command[2].event_timeout))
      }
    JAVASCRIPT

    find("#analytics-test-cta").click

    assert_signup_navigation("timeout")
    assert_equal "1", page.evaluate_script("sessionStorage.getItem('analyticsEventCount')")
    assert_equal "start_free_trial_click", page.evaluate_script("sessionStorage.getItem('analyticsEventName')")
    assert_equal "300", page.evaluate_script("sessionStorage.getItem('analyticsEventTimeout')")
  end

  test "unavailable or failing analytics never blocks ordinary CTA navigation" do
    {
      "unavailable" => "window.gtag = undefined",
      "error" => "window.gtag = () => { throw new Error('analytics unavailable') }"
    }.each do |scenario, analytics_setup|
      install_navigation_harness(analytics_setup, destination: scenario)

      find("#analytics-test-cta").click

      assert_signup_navigation(scenario)
    end
  end

  test "modifier and middle-click behavior stays native while keyboard activation remains ordinary" do
    visit signup_path
    install_analytics_harness
    wait_for_command("page_view")

    result = page.evaluate_script(<<~JAVASCRIPT)
      (() => {
        let prevented = false
        const link = document.createElement("a")
        link.href = "/signup"
        const controller = window.Stimulus.getControllerForElementAndIdentifier(document.body, "public-analytics")
        const baseEvent = {
          currentTarget: link,
          defaultPrevented: false,
          button: 0,
          altKey: false,
          ctrlKey: false,
          metaKey: false,
          shiftKey: false
        }
        controller.trackSignupCta({
          ...baseEvent,
          ctrlKey: true,
          preventDefault: () => { prevented = true }
        })

        return {
          modifiedPrevented: prevented,
          modifiedIsOrdinary: controller.isOrdinaryNavigation({ ...baseEvent, ctrlKey: true }),
          middleClickIsOrdinary: controller.isOrdinaryNavigation({ ...baseEvent, button: 1 }),
          keyboardIsOrdinary: controller.isOrdinaryNavigation({ ...baseEvent, detail: 0 })
        }
      })()
    JAVASCRIPT

    assert_equal false, result.fetch("modifiedPrevented")
    assert_equal false, result.fetch("modifiedIsOrdinary")
    assert_equal false, result.fetch("middleClickIsOrdinary")
    assert_equal true, result.fetch("keyboardIsOrdinary")
  end

  private

  def install_analytics_harness
    page.execute_script(<<~JAVASCRIPT)
      history.replaceState({}, "", "/?utm_source=instagram&utm_medium=social&utm_campaign=launch_2026&utm_content=hero_cta&utm_term=owner%40example.com&utm_invalid=account_42&email=owner%40example.com&account_id=account_42&vessel=vessel_42&document=document_42&token=verification_token#secret_fragment")
      Object.defineProperty(document, "referrer", {
        configurable: true,
        value: "https://partner.example/private/path?token=verification_token"
      })

      const originalAppendChild = document.head.appendChild.bind(document.head)
      window.__publicAnalyticsScriptLoads = 0
      document.head.appendChild = (node) => {
        if (node.id === "boat-binder-google-analytics") {
          window.__publicAnalyticsScriptLoads += 1
          window.__publicAnalyticsScriptSource = node.src
          node.src = "data:text/javascript,"
        }

        return originalAppendChild(node)
      }

      document.body.dataset.publicAnalyticsMeasurementIdValue = "G-TEST123"
      document.body.dataset.turbo = "false"
      document.body.dataset.controller = "public-analytics"
    JAVASCRIPT
  end

  def install_navigation_harness(analytics_setup, destination: "callback")
    visit signup_path
    install_analytics_harness
    wait_for_command("page_view")

    page.execute_script(<<~JAVASCRIPT)
      sessionStorage.removeItem("analyticsEventCount")
      sessionStorage.removeItem("analyticsEventName")
      sessionStorage.removeItem("analyticsEventTimeout")
      #{analytics_setup}

      const link = document.createElement("a")
      link.id = "analytics-test-cta"
      link.href = "#{signup_path}?delivery=#{destination}"
      link.textContent = "Start Free Trial"
      link.dataset.action = "click->public-analytics#trackSignupCta"
      document.body.appendChild(link)
    JAVASCRIPT

    assert_selector "#analytics-test-cta"
  end

  def assert_signup_navigation(delivery)
    assert_current_path "#{signup_path}?delivery=#{delivery}", ignore_query: false
    assert_no_selector "body[data-controller~='public-analytics']", visible: :all
    assert_no_selector "#boat-binder-google-analytics", visible: :all
  end

  def analytics_commands
    page.evaluate_script(<<~JAVASCRIPT)
      (window.dataLayer || []).map((command) => Array.from(command))
    JAVASCRIPT
  end

  def event_count(name)
    analytics_commands.count { |command| command.first == "event" && command.second == name }
  end

  def document_script_load_count
    page.evaluate_script("window.__publicAnalyticsScriptLoads")
  end

  def wait_for_command(name)
    wait_for_event_count(name, 1)
  end

  def wait_for_event_count(name, count)
    Selenium::WebDriver::Wait.new(timeout: 5).until { event_count(name) == count }
  end
end
