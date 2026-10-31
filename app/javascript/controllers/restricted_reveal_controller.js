import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["secret"]

  beforeCache() {
    this.secretTargets.forEach((secret) => {
      secret.textContent = ""
      secret.hidden = true
    })
  }
}
