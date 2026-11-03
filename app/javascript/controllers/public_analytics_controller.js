import { Controller } from "@hotwired/stimulus"

const ALLOWED_UTM_PARAMETERS = [
  "utm_source",
  "utm_medium",
  "utm_campaign",
  "utm_content",
  "utm_term"
]
const SAFE_UTM_VALUE = /^[a-zA-Z0-9][a-zA-Z0-9._~-]{0,99}$/
const GOOGLE_TAG_SCRIPT_ID = "boat-binder-google-analytics"
const INITIALIZED_KEY = "__boatBinderPublicAnalyticsInitialized"

export default class extends Controller {
  static values = { measurementId: String }

  connect() {
    if (!this.hasMeasurementIdValue || window[INITIALIZED_KEY]) return

    window[INITIALIZED_KEY] = true
    window.dataLayer = window.dataLayer || []
    window.gtag = window.gtag || function () { window.dataLayer.push(arguments) }

    const pageLocation = this.sanitizedPageLocation()
    const pageReferrer = this.sanitizedReferrer()

    window.gtag("consent", "default", {
      ad_storage: "denied",
      ad_user_data: "denied",
      ad_personalization: "denied",
      analytics_storage: "denied"
    })
    window.gtag("set", "ads_data_redaction", true)
    window.gtag("js", new Date())
    window.gtag("config", this.measurementIdValue, {
      allow_google_signals: false,
      allow_ad_personalization_signals: false,
      page_location: pageLocation,
      page_referrer: pageReferrer,
      send_page_view: false
    })
    window.gtag("event", "page_view", {
      page_location: pageLocation,
      page_referrer: pageReferrer
    })

    this.loadGoogleTag()
  }

  trackSignupCta(event) {
    const lastSentAt = Number(event.currentTarget.dataset.analyticsEventSentAt || 0)
    const now = Date.now()
    if (now - lastSentAt < 1000) return

    event.currentTarget.dataset.analyticsEventSentAt = now.toString()
    window.gtag?.("event", "start_free_trial_click")
  }

  sanitizedPageLocation() {
    const sanitizedUrl = new URL(window.location.origin + window.location.pathname)
    const currentParameters = new URLSearchParams(window.location.search)

    ALLOWED_UTM_PARAMETERS.forEach((name) => {
      const value = currentParameters.get(name)
      if (value && SAFE_UTM_VALUE.test(value)) sanitizedUrl.searchParams.set(name, value)
    })

    return sanitizedUrl.toString()
  }

  sanitizedReferrer() {
    if (!document.referrer) return ""

    try {
      const referrer = new URL(document.referrer)
      return ["http:", "https:"].includes(referrer.protocol) ? referrer.origin : ""
    } catch (_error) {
      return ""
    }
  }

  loadGoogleTag() {
    if (document.getElementById(GOOGLE_TAG_SCRIPT_ID)) return

    const script = document.createElement("script")
    script.id = GOOGLE_TAG_SCRIPT_ID
    script.async = true
    script.referrerPolicy = "no-referrer"
    script.src = `https://www.googletagmanager.com/gtag/js?id=${encodeURIComponent(this.measurementIdValue)}`
    document.head.appendChild(script)
  }
}
