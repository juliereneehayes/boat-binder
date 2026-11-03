require "application_system_test_case"

class PublicAnalyticsSystemTest < ApplicationSystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [ 1200, 900 ]

  test "sanitizes analytics payloads and prevents duplicate pageviews and CTA events" do
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
      const link = document.createElement("a")
      link.href = "/signup"
      const controller = window.Stimulus.getControllerForElementAndIdentifier(document.body, "public-analytics")
      controller.trackSignupCta({ currentTarget: link })
      controller.trackSignupCta({ currentTarget: link })
    JAVASCRIPT
    wait_for_command("start_free_trial_click")

    cta_commands = analytics_commands.select do |command|
      command.first == "event" && command.second == "start_free_trial_click"
    end
    assert_equal 1, cta_commands.length
    assert_equal [ "event", "start_free_trial_click" ], cta_commands.sole

    page.execute_script(<<~JAVASCRIPT)
      const controller = window.Stimulus.getControllerForElementAndIdentifier(document.body, "public-analytics")
      controller.handlePageShow({ persisted: true })
    JAVASCRIPT
    wait_for_event_count("page_view", 2)
    assert_equal 2, event_count("page_view")
    assert_equal 1, document_script_load_count
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
