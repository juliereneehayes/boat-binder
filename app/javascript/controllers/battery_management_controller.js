import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  open() {
    this.frame.hidden = false
  }

  close(event) {
    event.preventDefault()
    this.frame.replaceChildren()
    this.frame.hidden = true
  }

  reveal() {
    this.frame.scrollIntoView({ block: "center" })
  }

  get frame() {
    return this.element.querySelector("#service_visit_battery_management")
  }
}
