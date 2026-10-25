import { Controller } from "@hotwired/stimulus"
import { Turbo } from "@hotwired/turbo-rails"

export default class extends Controller {
  static values = {
    fastInterval: { type: Number, default: 5000 },
    slowInterval: { type: Number, default: 30000 },
    fastWindow: { type: Number, default: 60000 },
    scanAge: Number,
    remainingDuration: Number
  }

  connect() {
    this.connected = true
    this.dirty = false
    this.scanStartedAt = window.performance.now() - Math.max(this.scanAgeValue, 0)
    this.deadlineAt = window.performance.now() + Math.max(this.remainingDurationValue, 0)
    this.markDirty = this.markDirty.bind(this)
    this.handleVisibilityChange = this.handleVisibilityChange.bind(this)

    document.addEventListener("input", this.markDirty)
    document.addEventListener("change", this.markDirty)
    document.addEventListener("visibilitychange", this.handleVisibilityChange)
    this.schedulePendingCopy()
    this.scheduleRefresh()
  }

  disconnect() {
    this.connected = false
    this.cancelRefresh()
    this.cancelPendingCopy()
    document.removeEventListener("input", this.markDirty)
    document.removeEventListener("change", this.markDirty)
    document.removeEventListener("visibilitychange", this.handleVisibilityChange)
  }

  fastIntervalValueChanged() {
    this.rescheduleAfterValueChange()
  }

  slowIntervalValueChanged() {
    this.rescheduleAfterValueChange()
  }

  fastWindowValueChanged() {
    this.rescheduleAfterValueChange()
    this.reschedulePendingCopyAfterValueChange()
  }

  scanAgeValueChanged() {
    if (!this.connected) return

    this.scanStartedAt = window.performance.now() - Math.max(this.scanAgeValue, 0)
    this.rescheduleAfterValueChange()
    this.reschedulePendingCopyAfterValueChange()
  }

  remainingDurationValueChanged() {
    if (!this.connected) return

    this.deadlineAt = window.performance.now() + Math.max(this.remainingDurationValue, 0)
    this.rescheduleAfterValueChange()
  }

  rescheduleAfterValueChange() {
    if (!this.connected) return

    this.cancelRefresh()
    this.scheduleRefresh()
  }

  reschedulePendingCopyAfterValueChange() {
    if (!this.connected) return

    this.cancelPendingCopy()
    this.schedulePendingCopy()
  }

  schedulePendingCopy() {
    const scanAge = window.performance.now() - this.scanStartedAt
    const delay = this.fastWindowValue - scanAge
    if (delay <= 0) {
      this.showFinishingCopy()
      return
    }

    this.pendingCopyTimeout = window.setTimeout(() => this.showFinishingCopy(), delay)
  }

  cancelPendingCopy() {
    window.clearTimeout(this.pendingCopyTimeout)
    this.pendingCopyTimeout = undefined
  }

  showFinishingCopy() {
    document.querySelectorAll("[data-attachment-pending-copy]").forEach((copy) => {
      copy.textContent = "Finishing upload…"
    })
  }

  scheduleRefresh() {
    if (!this.connected || document.hidden) return

    const remainingDuration = this.deadlineAt - window.performance.now()
    if (remainingDuration <= 0) return

    const delay = Math.min(this.currentInterval(), remainingDuration)
    this.timeout = window.setTimeout(() => this.refresh(), delay)
  }

  cancelRefresh() {
    window.clearTimeout(this.timeout)
    this.timeout = undefined
  }

  refresh() {
    this.timeout = undefined
    if (!this.connected || document.hidden) return
    if (this.dirty || this.editableFormControlFocused()) {
      this.scheduleRefresh()
      return
    }

    Turbo.visit(window.location.href, { action: "replace" })
  }

  currentInterval() {
    const scanAge = window.performance.now() - this.scanStartedAt

    return scanAge < this.fastWindowValue ? this.fastIntervalValue : this.slowIntervalValue
  }

  markDirty(event) {
    if (event.target?.closest?.("form")) this.dirty = true
  }

  editableFormControlFocused() {
    const activeElement = document.activeElement
    if (!(activeElement instanceof Element) || !activeElement.closest("form")) return false

    return activeElement.matches(
      "input:not([type='hidden']):not([disabled]):not([readonly]), " +
      "textarea:not([disabled]):not([readonly]), select:not([disabled]), [contenteditable='true']"
    )
  }

  handleVisibilityChange() {
    this.cancelRefresh()
    if (!document.hidden) this.scheduleRefresh()
  }
}
