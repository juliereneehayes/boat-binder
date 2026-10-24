import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

export default class extends Controller {
  static values = { interval: { type: Number, default: 5000 } }

  connect() {
    this.connected = true
    this.scheduleRefresh()
  }

  disconnect() {
    this.connected = false
    this.cancelRefresh()
  }

  intervalValueChanged() {
    if (!this.connected) return

    this.cancelRefresh()
    this.scheduleRefresh()
  }

  scheduleRefresh() {
    this.timeout = window.setTimeout(() => this.refresh(), this.intervalValue)
  }

  cancelRefresh() {
    window.clearTimeout(this.timeout)
  }

  refresh() {
    Turbo.visit(window.location.href, { action: "replace" })
  }
}
