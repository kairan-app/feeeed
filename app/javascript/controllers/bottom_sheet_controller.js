import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["container", "overlay", "sheet"]

  connect() {
    this.isOpen = false
  }

  toggle() {
    if (this.isOpen) {
      this.close()
    } else {
      this.open()
    }
  }

  open() {
    this.isOpen = true
    this.containerTarget.classList.remove("pointer-events-none")
    this.overlayTarget.classList.remove("bg-black/0", "pointer-events-none")
    this.overlayTarget.classList.add("bg-black/50", "pointer-events-auto")
    this.sheetTarget.classList.remove("translate-y-full")
    this.sheetTarget.classList.add("translate-y-0")
    document.body.style.overflow = "hidden"
  }

  close() {
    this.isOpen = false
    this.overlayTarget.classList.remove("bg-black/50", "pointer-events-auto")
    this.overlayTarget.classList.add("bg-black/0", "pointer-events-none")
    this.sheetTarget.classList.remove("translate-y-0")
    this.sheetTarget.classList.add("translate-y-full")

    setTimeout(() => {
      this.containerTarget.classList.add("pointer-events-none")
      document.body.style.overflow = ""
    }, 300)
  }

  closeOnOverlay(event) {
    if (event.target === this.overlayTarget) {
      this.close()
    }
  }
}
