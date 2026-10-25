import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [ "surface" ]
  static values = {
    flow: String,
    identity: String,
    state: String
  }

  connect() {
    if (this.hasSurfaceTarget && this.surfaceTarget.uploadPreviewObjectUrls?.length) {
      this.surfaceTarget.dataset.uploadPreviewIdentity = this.identityValue
    }
  }

  disconnect() {
    if (!this.hasSurfaceTarget) return

    const surface = this.surfaceTarget
    queueMicrotask(() => {
      if (!surface.isConnected) this.releaseObjectUrls(surface)
    })
  }

  select(event) {
    const files = Array.from(event.target.files || []).filter((file) => file.type.startsWith("image/"))
    if (!this.hasSurfaceTarget || files.length === 0) return

    this.releaseObjectUrls()
    const objectUrls = files.map((file) => URL.createObjectURL(file))
    this.surfaceTarget.uploadPreviewObjectUrls = objectUrls
    this.surfaceTarget.uploadPreviewSubmitted = false
    this.surfaceTarget.dataset.uploadPreviewIdentity = this.identityValue
    this.surfaceTarget.dataset.turboPermanent = ""
    this.surfaceTarget.hidden = false
    this.render(files, objectUrls)
  }

  submit() {
    if (!this.hasSurfaceTarget || !this.surfaceTarget.uploadPreviewObjectUrls?.length) return

    this.surfaceTarget.uploadPreviewSubmitted = true
  }

  beforeRender(event) {
    if (!this.hasSurfaceTarget) return

    const newSurface = event.detail.newBody.querySelector(`#${CSS.escape(this.surfaceTarget.id)}`)
    if (!this.surfaceTarget.uploadPreviewObjectUrls?.length) {
      this.surfaceTarget.removeAttribute("data-turbo-permanent")
      newSurface?.removeAttribute("data-turbo-permanent")
      return
    }

    const newController = newSurface?.closest("[data-controller~='upload-preview']")
    const newFlow = newController?.dataset.uploadPreviewFlowValue
    const newIdentity = newController?.dataset.uploadPreviewIdentityValue || ""
    const newState = newController?.dataset.uploadPreviewStateValue
    const currentIdentity = this.surfaceTarget.dataset.uploadPreviewIdentity || this.identityValue || ""
    const successfulCreate = currentIdentity === "" && this.stateValue === "form"
    const sameRecord = successfulCreate || currentIdentity === newIdentity
    const keepPreview = this.surfaceTarget.uploadPreviewSubmitted &&
      newSurface &&
      newFlow === this.flowValue &&
      newState === "pending" &&
      sameRecord

    if (keepPreview) return

    this.surfaceTarget.removeAttribute("data-turbo-permanent")
    newSurface?.removeAttribute("data-turbo-permanent")
    this.releaseObjectUrls()
  }

  render(files, objectUrls) {
    const grid = document.createElement("div")
    grid.className = files.length > 1 ? "grid grid-cols-2 gap-2" : ""

    objectUrls.forEach((objectUrl, index) => {
      const image = document.createElement("img")
      image.src = objectUrl
      image.alt = files.length > 1 ? `Selected upload ${index + 1}` : "Selected upload"
      image.className = files.length > 1 ?
        "aspect-[4/3] w-full rounded-md object-cover" :
        "aspect-[16/9] w-full object-cover"
      image.dataset.uploadPreviewLocal = "true"
      grid.appendChild(image)
    })

    const status = document.createElement("p")
    status.className = "absolute inset-x-3 bottom-3 rounded-md bg-slate-950/80 px-3 py-2 text-sm font-bold text-white shadow-sm"
    status.textContent = "Saving…"
    status.dataset.uploadPreviewStatus = "true"

    this.surfaceTarget.replaceChildren(grid, status)
  }

  releaseObjectUrls(surface = this.surfaceTarget) {
    const objectUrls = surface.uploadPreviewObjectUrls || []
    objectUrls.forEach((objectUrl) => URL.revokeObjectURL(objectUrl))
    surface.uploadPreviewObjectUrls = []
    surface.uploadPreviewSubmitted = false
  }
}
