import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = {
    url: String,
    currentDays: Number,
    channelGroupId: String
  }

  connect() {
    this.isLoading = false
    this.hasMore = true
    this.currentDays = this.currentDaysValue

    this.loadingIndicator = document.getElementById('loading-indicator')
    this.noMoreContent = document.getElementById('no-more-content')
    this.container = this.element

    this.bindScrollEvent()
  }

  disconnect() {
    this.unbindScrollEvent()
  }

  bindScrollEvent() {
    this.handleScroll = this.handleScroll.bind(this)
    window.addEventListener('scroll', this.handleScroll)
  }

  unbindScrollEvent() {
    window.removeEventListener('scroll', this.handleScroll)
  }

  handleScroll() {
    if (this.isLoading || !this.hasMore) return

    const scrollTop = window.pageYOffset || document.documentElement.scrollTop
    const windowHeight = window.innerHeight
    const documentHeight = document.documentElement.scrollHeight

    // ページの下部から100px以内にスクロールした場合に次のデータを読み込む
    if (scrollTop + windowHeight >= documentHeight - 100) {
      this.loadMore()
    }
  }

  async loadMore() {
    if (this.isLoading || !this.hasMore) return

    this.isLoading = true
    this.showLoadingIndicator()

    try {
      const params = new URLSearchParams({
        current_days: this.currentDays,
        channel_group_id: this.channelGroupIdValue || ''
      })

      const response = await fetch(`${this.urlValue}?${params}`)
      const data = await response.json()

      if (data.has_more && data.html.trim() !== '') {
        this.appendContent(data.html)
        this.currentDays = data.next_days
      } else {
        this.hasMore = false
        this.showNoMoreContent()
      }
    } catch (error) {
      console.error('Error loading more content:', error)
    } finally {
      this.isLoading = false
      this.hideLoadingIndicator()
    }
  }

  appendContent(html) {
    const tempDiv = document.createElement('div')
    tempDiv.innerHTML = html

    while (tempDiv.firstChild) {
      this.container.insertBefore(tempDiv.firstChild, this.loadingIndicator)
    }
  }

  showLoadingIndicator() {
    this.loadingIndicator?.classList.remove('hidden')
  }

  hideLoadingIndicator() {
    this.loadingIndicator?.classList.add('hidden')
  }

  showNoMoreContent() {
    this.noMoreContent?.classList.remove('hidden')
  }
}
