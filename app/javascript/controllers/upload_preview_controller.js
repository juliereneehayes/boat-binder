import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [ "surface" ]
  static values = {
    existingCount: { type: Number, default: 0 },
    finishingDelay: { type: Number, default: 60000 },
    flow: String,
    identity: String,
    state: String
  }

  connect() {
    if (!this.hasSurfaceTarget) return

    if (this.surfaceTarget.uploadPreviewObjectUrls?.length) {
      this.surfaceTarget.dataset.uploadPreviewIdentity = this.identityValue
      return
    }

    this.captureServerSurface(this.surfaceTarget)
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
    if (!this.hasSurfaceTarget) return

    if (files.length === 0) {
      if (this.surfaceTarget.uploadPreviewObjectUrls?.length) this.resetPreview()
      return
    }

    this.releaseObjectUrls()
    const objectUrls = files.map((file) => URL.createObjectURL(file))
    this.surfaceTarget.uploadPreviewObjectUrls = objectUrls
    this.surfaceTarget.uploadPreviewSubmitted = false
    this.surfaceTarget.uploadPreviewExistingServerPhotoCount = this.existingCountValue
    this.surfaceTarget.dataset.uploadPreviewIdentity = this.identityValue
    this.surfaceTarget.dataset.turboPermanent = ""
    this.surfaceTarget.hidden = false
    this.render(files, objectUrls)
  }

  submit() {
    if (!this.hasSurfaceTarget || !this.surfaceTarget.uploadPreviewObjectUrls?.length) return

    this.surfaceTarget.uploadPreviewSubmitted = true
  }

  submitEnd(event) {
    if (!this.hasSurfaceTarget || !this.element.contains(event.target)) return
    if (event.detail.success === false) this.surfaceTarget.uploadPreviewSubmitted = false
  }

  beforeCache() {
    if (!this.hasSurfaceTarget) return

    if (this.surfaceTarget.uploadPreviewObjectUrls?.length) this.resetPreview()
    this.restoreSuppressedServerPhotos()
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

    if (keepPreview) {
      this.captureServerSurface(newSurface)
      this.suppressNewServerPhotos(newController)
      return
    }

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
      image.decoding = "async"
      image.className = files.length > 1 ?
        "aspect-[4/3] w-full rounded-md object-cover" :
        "aspect-[16/9] w-full object-cover"
      image.dataset.uploadPreviewLocal = "true"
      grid.appendChild(image)
    })

    const status = document.createElement("p")
    status.className = "absolute inset-x-3 bottom-3 rounded-md bg-slate-950/80 px-3 py-2 text-sm font-bold text-white shadow-sm"
    status.textContent = "Saving…"
    status.role = "status"
    status.setAttribute("aria-live", "polite")
    status.dataset.uploadPreviewStatus = "true"

    this.surfaceTarget.replaceChildren(grid, status)
    this.scheduleFinishingCopy()
  }

  scheduleFinishingCopy() {
    window.clearTimeout(this.surfaceTarget.uploadPreviewStatusTimer)
    this.surfaceTarget.uploadPreviewStatusTimer = window.setTimeout(() => {
      const status = this.surfaceTarget.querySelector("[data-upload-preview-status]")
      if (status && this.surfaceTarget.uploadPreviewObjectUrls?.length) {
        status.textContent = "Finishing upload…"
      }
    }, this.finishingDelayValue)
  }

  captureServerSurface(source) {
    this.surfaceTarget.uploadPreviewServerContent = Array.from(source.childNodes, (node) => node.cloneNode(true))
    this.surfaceTarget.uploadPreviewServerHidden = source.hidden
  }

  resetPreview() {
    const surface = this.surfaceTarget
    this.releaseObjectUrls(surface)
    const content = (surface.uploadPreviewServerContent || []).map((node) => node.cloneNode(true))
    surface.replaceChildren(...content)
    surface.hidden = surface.uploadPreviewServerHidden ?? false
    surface.removeAttribute("data-turbo-permanent")
    delete surface.dataset.uploadPreviewIdentity
  }

  suppressNewServerPhotos(controller) {
    if (!controller || this.flowValue !== "service-visit-photos") return

    const existingCount = this.surfaceTarget.uploadPreviewExistingServerPhotoCount || 0
    const serverPhotos = controller.querySelectorAll("[data-upload-preview-server-photo]")
    serverPhotos.forEach((photo, index) => {
      if (index < existingCount) return

      photo.hidden = true
      photo.classList.add("hidden")
      photo.dataset.uploadPreviewSuppressed = "true"
    })
  }

  restoreSuppressedServerPhotos() {
    this.element.querySelectorAll("[data-upload-preview-suppressed]").forEach((photo) => {
      photo.hidden = false
      photo.classList.remove("hidden")
      delete photo.dataset.uploadPreviewSuppressed
    })
  }

  releaseObjectUrls(surface = this.surfaceTarget) {
    const objectUrls = surface.uploadPreviewObjectUrls || []
    objectUrls.forEach((objectUrl) => URL.revokeObjectURL(objectUrl))
    window.clearTimeout(surface.uploadPreviewStatusTimer)
    surface.uploadPreviewStatusTimer = undefined
    surface.uploadPreviewObjectUrls = []
    surface.uploadPreviewSubmitted = false
  }
}
