import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["role", "account", "accessLevel", "accessLabel", "ownerHelp", "internalHelp"]

  connect() {
    this.refresh()
  }

  refresh() {
    const internal = this.roleTarget.value === "admin" || this.roleTarget.value === "captain"

    this.ownerHelpTarget.classList.toggle("hidden", internal)
    this.internalHelpTarget.classList.toggle("hidden", !internal)

    this.accountTargets.forEach((checkbox, index) => {
      checkbox.disabled = internal
      checkbox.checked = internal || checkbox.dataset.ownerChecked === "true"

      const label = this.accessLabelTargets[index]
      label.classList.toggle("border-slate-200", internal)
      label.classList.toggle("bg-slate-50", internal)
      label.classList.toggle("text-slate-500", internal)
      label.classList.toggle("border-slate-300", !internal)
    })

    this.refreshAccountAccess()
  }

  refreshAccountAccess() {
    const internal = this.roleTarget.value === "admin" || this.roleTarget.value === "captain"

    this.accessLevelTargets.forEach((select, index) => {
      select.disabled = internal || !this.accountTargets[index].checked
    })
  }
}
