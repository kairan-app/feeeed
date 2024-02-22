import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="item-modal"
export default class extends Controller {
  open(event) {
    const { url } = event.detail
    document.body.classList.add("with-item-modal")
    this.element.querySelector("iframe").src = url
  }

  close() {
    document.body.classList.remove("with-item-modal")
  }
}
