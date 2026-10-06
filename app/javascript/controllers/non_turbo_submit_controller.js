import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { submittingText: String }

  disable(event) {
    const submitter = event.submitter
    if (!submitter) return

    submitter.disabled = true
    if (!this.hasSubmittingTextValue) return

    if (submitter.tagName === "INPUT") {
      submitter.value = this.submittingTextValue
    } else {
      submitter.textContent = this.submittingTextValue
    }
  }
}
