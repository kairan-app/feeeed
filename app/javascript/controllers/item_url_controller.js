import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="item-url"
export default class extends Controller {
  open(event) {
    event.preventDefault()

    const url = this.element.href
    const e = new CustomEvent("open-item-modal", { detail: { url } })
    window.dispatchEvent(e)
  }
}
