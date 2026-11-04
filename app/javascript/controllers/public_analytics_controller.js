import { Controller } from "@hotwired/stimulus"

const ALLOWED_UTM_PARAMETERS = [
  "utm_source",
  "utm_medium",
  "utm_campaign",
  "utm_content",
  "utm_term"
]
const SAFE_UTM_VALUE = /^[a-z0-9]+(?:_[a-z0-9]+)*$/
const MAX_UTM_VALUE_LENGTH = 50
const GOOGLE_TAG_SCRIPT_ID = "boat-binder-google-analytics"
const INITIALIZED_KEY = "__boatBinderPublicAnalyticsInitialized"
const SIGNUP_NAVIGATION_TIMEOUT = 300
const SIGNUP_NAVIGATION_RECOVERY_TIMEOUT = 2000

export default class extends Controller {
  static values = { measurementId: String }

  connect() {
    this.handlePageShow = this.handlePageShow.bind(this)
    window.addEventListener("pageshow", this.handlePageShow)
    this.initializeAnalytics()
  }

  disconnect() {
    window.removeEventListener("pageshow", this.handlePageShow)
    this.resetSignupNavigation()
  }

  handlePageShow(event) {
    this.resetSignupNavigation()
    if (!event.persisted) return

    window[INITIALIZED_KEY] = false
    this.initializeAnalytics()
  }

  initializeAnalytics() {
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
    if (event.defaultPrevented) return

    if (!this.isOrdinaryNavigation(event)) {
      this.sendSignupCtaEvent()
      return
    }

    if (this.signupNavigationPending) {
      event.preventDefault()
      return
    }

    if (typeof window.gtag !== "function") return

    event.preventDefault()
    this.signupNavigationPending = true
    const navigationOperation = Symbol()
    this.signupNavigationOperation = navigationOperation

    const destination = event.currentTarget.href
    let navigated = false
    const navigate = () => {
      if (navigated || this.signupNavigationOperation !== navigationOperation) return

      navigated = true
      window.clearTimeout(this.signupNavigationFallbackTimeout)
      this.signupNavigationFallbackTimeout = undefined
      this.signupNavigationRecoveryTimeout = window.setTimeout(
        () => this.resetSignupNavigation(),
        SIGNUP_NAVIGATION_RECOVERY_TIMEOUT
      )

      try {
        window.location.assign(destination)
      } catch (_error) {
        this.resetSignupNavigation()
        window.location.href = destination
      }
    }

    this.signupNavigationFallbackTimeout = window.setTimeout(navigate, SIGNUP_NAVIGATION_TIMEOUT)

    try {
      window.gtag("event", "start_free_trial_click", {
        event_callback: navigate,
        event_timeout: SIGNUP_NAVIGATION_TIMEOUT
      })
    } catch (_error) {
      navigate()
    }
  }

  resetSignupNavigation() {
    this.signupNavigationPending = false
    this.signupNavigationOperation = undefined
    window.clearTimeout(this.signupNavigationFallbackTimeout)
    window.clearTimeout(this.signupNavigationRecoveryTimeout)
    this.signupNavigationFallbackTimeout = undefined
    this.signupNavigationRecoveryTimeout = undefined
  }

  isOrdinaryNavigation(event) {
    return !event.defaultPrevented &&
      event.button === 0 &&
      !event.altKey &&
      !event.ctrlKey &&
      !event.metaKey &&
      !event.shiftKey &&
      !event.currentTarget.hasAttribute("download") &&
      (!event.currentTarget.target || event.currentTarget.target === "_self")
  }

  sendSignupCtaEvent() {
    if (typeof window.gtag !== "function") return

    try {
      window.gtag("event", "start_free_trial_click")
    } catch (_error) {
      // Analytics must never interfere with native link behavior.
    }
  }

  sanitizedPageLocation() {
    const sanitizedUrl = new URL(window.location.origin + window.location.pathname)
    const currentParameters = new URLSearchParams(window.location.search)

    ALLOWED_UTM_PARAMETERS.forEach((name) => {
      const value = currentParameters.get(name)
      if (value && value.length <= MAX_UTM_VALUE_LENGTH && SAFE_UTM_VALUE.test(value)) {
        sanitizedUrl.searchParams.set(name, value)
      }
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
