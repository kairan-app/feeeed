import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["urlInput", "addButton", "searchInput", "toggle"]

  validateUrl() {
    this.addButtonTarget.disabled = this.urlInputTarget.value.trim() === ""
  }

  focusSearchOnOpen() {
    if (this.toggleTarget.checked && this.hasSearchInputTarget) {
      requestAnimationFrame(() => this.searchInputTarget.focus())
    }
  }
}
