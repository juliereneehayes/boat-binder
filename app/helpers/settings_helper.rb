module SettingsHelper
  PLATFORM_NAMES = {
    "Android" => "Android device",
    "iPad" => "iPad",
    "iPhone" => "iPhone",
    "Linux" => "Linux device",
    "Macintosh" => "Mac",
    "Windows" => "Windows device"
  }.freeze

  def session_device_description(session)
    agent = UserAgent.parse(session.user_agent.to_s)
    browser = agent.browser.presence || "Unknown browser"
    platform = PLATFORM_NAMES.fetch(agent.platform, agent.mobile? ? "mobile device" : "unknown device")
    "#{browser} on #{platform}"
  rescue StandardError
    "Unknown browser on unknown device"
  end
end
