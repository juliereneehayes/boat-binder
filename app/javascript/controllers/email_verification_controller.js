import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["failure", "form", "token", "working"]

  connect() {
    const fragment = window.location.hash
    window.history.replaceState(null, "", `${window.location.pathname}${window.location.search}`)

    const token = this.verificationToken(fragment)
    if (!token) {
      this.showFailure()
      return
    }

    this.tokenTarget.value = token
    this.formTarget.requestSubmit()
  }

  verificationToken(fragment) {
    const parameters = new URLSearchParams(fragment.replace(/^#/, ""))
    const keys = Array.from(parameters.keys())
    if (keys.length !== 1 || keys[0] !== "token") return null

    const token = parameters.get("token")
    if (!token || !/^[A-Za-z0-9_=-]{64,1024}$/.test(token)) return null

    return token
  }

  showFailure() {
    this.workingTarget.classList.add("hidden")
    this.failureTarget.classList.remove("hidden")
  }
}
