import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["source", "button"]
  static values = { successLabel: { type: String, default: "Copied!" } }

  async copy() {
    const text = this.sourceTarget.innerText
    try {
      await navigator.clipboard.writeText(text)
      this.#flashLabel(this.successLabelValue)
    } catch (e) {
      this.#flashLabel("Failed")
    }
  }

  disconnect() {
    clearTimeout(this.resetTimeout)
  }

  #flashLabel(label) {
    if (!this.hasButtonTarget) return
    const original = this.buttonTarget.dataset.originalLabel || this.buttonTarget.innerText
    this.buttonTarget.dataset.originalLabel = original
    this.buttonTarget.innerText = label
    clearTimeout(this.resetTimeout)
    this.resetTimeout = setTimeout(() => {
      this.buttonTarget.innerText = original
    }, 1500)
  }
}
