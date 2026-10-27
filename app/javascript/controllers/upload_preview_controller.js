import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = [ "surface" ]
  static values = {
    existingCount: { type: Number, default: 0 },
    flow: String,
    identity: String,
    state: String
  }

  connect() {
    if (!this.hasSurfaceTarget) return

    if (this.surfaceTarget.uploadPreviewObjectUrls?.length) {
      if (this.previewMatchesCurrentContext()) return

      this.releaseObjectUrls()
    }

    this.captureServerSurface(this.surfaceTarget)
  }

  disconnect() {
    if (!this.hasSurfaceTarget) return

    const surface = this.surfaceTarget
    queueMicrotask(() => {
      if (!surface.isConnected && surface.uploadPreviewObjectUrls?.length) this.releaseObjectUrls(surface)
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
    const surface = this.surfaceTarget
    surface.uploadPreviewFiles = files
    surface.uploadPreviewObjectUrls = objectUrls
    surface.uploadPreviewSubmitted = false
    surface.uploadPreviewFlow = this.flowValue
    surface.uploadPreviewIdentity = this.identityValue
    surface.uploadPreviewExistingServerPhotoCount = this.existingCountValue
    surface.hidden = false
    this.render(surface, files, objectUrls)
  }

  submit() {
    if (!this.hasSurfaceTarget || !this.surfaceTarget.uploadPreviewObjectUrls?.length) return

    this.surfaceTarget.uploadPreviewSubmitted = true
    this.setStatus("Processing photo…")
  }

  submitEnd(event) {
    if (!this.hasSurfaceTarget || !this.element.contains(event.target)) return
    if (event.detail.success === false) {
      this.surfaceTarget.uploadPreviewSubmitted = false
      this.setStatus("Selected photo")
    }
  }

  beforeCache() {
    if (!this.hasSurfaceTarget || !this.surfaceTarget.uploadPreviewObjectUrls?.length) return

    const surface = this.surfaceTarget
    if (!surface.uploadPreviewSubmitted) {
      this.resetPreview()
      return
    }

    surface.uploadPreviewLocalContent = Array.from(surface.childNodes)
    this.restoreServerSurface(surface)

    queueMicrotask(() => {
      if (!surface.isConnected || !surface.uploadPreviewObjectUrls?.length) return
      if (!surface.uploadPreviewLocalContent?.length) return

      surface.replaceChildren(...surface.uploadPreviewLocalContent)
      surface.uploadPreviewLocalContent = undefined
      surface.hidden = false
    })
  }

  beforeRender(event) {
    if (!this.hasSurfaceTarget || !this.surfaceTarget.uploadPreviewObjectUrls?.length) return

    const newSurface = event.detail.newBody.querySelector(`#${CSS.escape(this.surfaceTarget.id)}`)
    const newController = newSurface?.closest("[data-controller~='upload-preview']")
    const newFlow = newController?.dataset.uploadPreviewFlowValue
    const newIdentity = newController?.dataset.uploadPreviewIdentityValue || ""
    const newState = newController?.dataset.uploadPreviewStateValue
    const currentIdentity = this.surfaceTarget.uploadPreviewIdentity || ""
    const successfulCreate = currentIdentity === "" && this.stateValue === "form"
    const sameRecord = successfulCreate || currentIdentity === newIdentity
    const keepPreview = this.surfaceTarget.uploadPreviewSubmitted === true &&
      newSurface &&
      newFlow === this.flowValue &&
      newState === "pending" &&
      sameRecord

    if (!keepPreview) {
      this.releaseObjectUrls()
      return
    }

    this.suppressNewServerPhotos(newController)
    this.transferPreview(this.surfaceTarget, newSurface, newIdentity)
  }

  render(surface, files, objectUrls) {
    const grid = document.createElement("div")
    grid.className = files.length > 1 ? "grid grid-cols-2 gap-2" : ""

    objectUrls.forEach((objectUrl, index) => {
      const image = document.createElement("img")
      image.src = objectUrl
      image.alt = files.length > 1 ? `Selected upload ${index + 1}` : "Selected upload"
      image.decoding = "async"
      image.className = files.length > 1 ?
        "aspect-[4/3] w-full rounded-md object-cover" :
        "aspect-[16/10] w-full object-cover"
      image.dataset.uploadPreviewLocal = "true"
      grid.appendChild(image)
    })

    const status = document.createElement("p")
    status.className = "absolute inset-x-3 bottom-3 rounded-md bg-slate-950/80 px-3 py-2 text-sm font-bold text-white shadow-sm"
    status.textContent = files.length > 1 ? "Selected photos" : "Selected photo"
    status.dataset.uploadPreviewStatus = "true"

    surface.replaceChildren(grid, status)
  }

  setStatus(copy) {
    const status = this.surfaceTarget.querySelector("[data-upload-preview-status]")
    if (status) status.textContent = copy
  }

  transferPreview(surface, newSurface, newIdentity) {
    const localContent = surface.uploadPreviewLocalContent || Array.from(surface.childNodes)
    const serverContent = Array.from(newSurface.childNodes, (node) => node.cloneNode(true))
    const serverHidden = newSurface.hidden

    newSurface.replaceChildren(...localContent)
    newSurface.hidden = false
    newSurface.uploadPreviewFiles = surface.uploadPreviewFiles
    newSurface.uploadPreviewObjectUrls = surface.uploadPreviewObjectUrls
    newSurface.uploadPreviewSubmitted = true
    newSurface.uploadPreviewFlow = this.flowValue
    newSurface.uploadPreviewIdentity = newIdentity
    newSurface.uploadPreviewExistingServerPhotoCount = surface.uploadPreviewExistingServerPhotoCount
    newSurface.uploadPreviewServerContent = serverContent
    newSurface.uploadPreviewServerHidden = serverHidden

    surface.uploadPreviewFiles = []
    surface.uploadPreviewObjectUrls = []
    surface.uploadPreviewSubmitted = false
    surface.uploadPreviewLocalContent = undefined
  }

  captureServerSurface(surface) {
    surface.uploadPreviewServerContent = Array.from(surface.childNodes, (node) => node.cloneNode(true))
    surface.uploadPreviewServerHidden = surface.hidden
  }

  restoreServerSurface(surface) {
    const content = (surface.uploadPreviewServerContent || []).map((node) => node.cloneNode(true))
    surface.replaceChildren(...content)
    surface.hidden = surface.uploadPreviewServerHidden ?? false
  }

  resetPreview() {
    const surface = this.surfaceTarget
    this.releaseObjectUrls(surface)
    this.restoreServerSurface(surface)
  }

  suppressNewServerPhotos(controller) {
    if (!controller || this.flowValue !== "service-visit-photos") return

    const existingCount = this.surfaceTarget.uploadPreviewExistingServerPhotoCount || 0
    const serverPhotos = controller.querySelectorAll("[data-upload-preview-server-photo]")
    serverPhotos.forEach((photo, index) => {
      if (index < existingCount) return

      photo.hidden = true
      photo.classList.add("hidden")
    })
  }

  previewMatchesCurrentContext() {
    return this.surfaceTarget.uploadPreviewFlow === this.flowValue &&
      this.surfaceTarget.uploadPreviewIdentity === this.identityValue
  }

  releaseObjectUrls(surface = this.surfaceTarget) {
    const objectUrls = surface.uploadPreviewObjectUrls || []
    objectUrls.forEach((objectUrl) => URL.revokeObjectURL(objectUrl))
    surface.uploadPreviewObjectUrls = []
    surface.uploadPreviewFiles = []
    surface.uploadPreviewSubmitted = false
    surface.uploadPreviewLocalContent = undefined
    surface.uploadPreviewFlow = undefined
    surface.uploadPreviewIdentity = undefined
    surface.uploadPreviewExistingServerPhotoCount = undefined
  }
}
