import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["masked", "secret"]

  beforeCache() {
    this.scrub()
  }

  pageHide() {
    this.scrub()
  }

  pageShow() {
    this.scrub()
  }

  scrub() {
    this.secretTargets.forEach((secret) => {
      secret.textContent = ""
      secret.hidden = true
    })

    if (this.hasMaskedTarget) {
      this.element.replaceChildren(this.maskedTarget.content.cloneNode(true))
    }
  }
}
