import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["urlInput", "addButton"]

  validateUrl() {
    this.addButtonTarget.disabled = this.urlInputTarget.value.trim() === ""
  }
}
