import { Controller } from "@hotwired/stimulus"

// ページ内の全オーディオアイテムを一括でキューに追加するコントローラー
export default class extends Controller {
  addAll() {
    // ページ内の audio-item コントローラーを持つ要素を全て取得
    const audioItems = document.querySelectorAll("[data-controller~='audio-item']")

    const items = Array.from(audioItems).map(el => {
      return {
        itemId: parseInt(el.dataset.audioItemItemIdValue, 10),
        title: el.dataset.audioItemTitleValue,
        url: el.dataset.audioItemUrlValue,
        channelTitle: el.dataset.audioItemChannelTitleValue,
        imageUrl: el.dataset.audioItemImageUrlValue
      }
    }).filter(item => item.url) // URLがあるもののみ

    if (items.length > 0) {
      document.dispatchEvent(new CustomEvent("audio:addAllToQueue", {
        detail: { items }
      }))
      this.showFeedback(items.length)
    }
  }

  showFeedback(count) {
    const button = this.element.querySelector("button") || this.element
    const originalText = button.innerHTML
    button.innerHTML = `<span class="material-symbols-outlined text-sm">check</span> ${count}件追加`
    button.disabled = true
    setTimeout(() => {
      button.innerHTML = originalText
      button.disabled = false
    }, 2000)
  }
}
