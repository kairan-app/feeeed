import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  submit(event) {
    const checkbox = event.target
    const label = checkbox.closest("label")

    if (label) {
      // Optimistic UI: 即座に背景色を切り替える
      if (checkbox.checked) {
        label.classList.remove("bg-gray-100", "text-gray-600")
        label.classList.add("bg-blue-100", "text-blue-800")
      } else {
        label.classList.remove("bg-blue-100", "text-blue-800")
        label.classList.add("bg-gray-100", "text-gray-600")
      }
    }

    this.element.requestSubmit()
  }
}
