import { Controller } from "@hotwired/stimulus"

// 各Itemの「キューに追加」「再生」ボタンを制御するコントローラー
export default class extends Controller {
  static values = {
    itemId: Number,
    title: String,
    url: String,
    channelTitle: String,
    imageUrl: String
  }

  addToQueue() {
    this.dispatchAudioEvent("audio:addToQueue", this.buildItem())
    this.showAddedFeedback()
  }

  playNow() {
    this.dispatchAudioEvent("audio:playNow", this.buildItem())
  }

  buildItem() {
    return {
      itemId: this.itemIdValue,
      title: this.titleValue,
      url: this.urlValue,
      channelTitle: this.channelTitleValue,
      imageUrl: this.imageUrlValue
    }
  }

  dispatchAudioEvent(eventName, detail) {
    document.dispatchEvent(new CustomEvent(eventName, { detail }))
  }

  showAddedFeedback() {
    // 一時的にボタンテキストを変更してフィードバック
    const button = this.element.querySelector("[data-audio-item-add-button]")
    if (button) {
      const originalText = button.innerHTML
      button.innerHTML = '<span class="material-symbols-outlined text-sm">check</span> 追加済み'
      button.disabled = true
      setTimeout(() => {
        button.innerHTML = originalText
        button.disabled = false
      }, 1500)
    }
  }
}
