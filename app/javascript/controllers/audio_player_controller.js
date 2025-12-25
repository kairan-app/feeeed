import { Controller } from "@hotwired/stimulus"

// グローバル音声プレイヤーのメインコントローラー
// ページ遷移しても状態を維持する
export default class extends Controller {
  static targets = [
    "audio",
    "playButton",
    "playIcon",
    "progress",
    "progressBar",
    "currentTime",
    "duration",
    "speed",
    "title",
    "channel",
    "queueCount",
    "queuePanel",
    "queueList",
    "container",
    // モバイル用ターゲット
    "playButtonMobile",
    "playIconMobile",
    "progressMobile",
    "progressBarMobile",
    "currentTimeMobile",
    "durationMobile",
    "speedMobile",
    "titleMobile",
    "channelMobile",
    "queueCountMobile"
  ]

  static values = {
    queue: { type: Array, default: [] },
    currentIndex: { type: Number, default: 0 },
    playbackRate: { type: Number, default: 1.0 },
    isPlaying: { type: Boolean, default: false }
  }

  connect() {
    this.loadFromStorage()
    this.setupEventListeners()
    this.updateUI()
  }

  disconnect() {
    this.saveToStorage()
  }

  // === Storage ===
  loadFromStorage() {
    try {
      const data = localStorage.getItem("feeeed:audioPlayer")
      if (data) {
        const parsed = JSON.parse(data)
        this.queueValue = parsed.queue || []
        this.currentIndexValue = parsed.currentIndex || 0
        this.playbackRateValue = parsed.playbackRate || 1.0

        if (this.queueValue.length > 0 && parsed.currentTime) {
          this.pendingSeek = parsed.currentTime
        }
      }
    } catch (e) {
      console.error("Failed to load audio player state:", e)
    }
  }

  saveToStorage() {
    try {
      const data = {
        queue: this.queueValue,
        currentIndex: this.currentIndexValue,
        playbackRate: this.playbackRateValue,
        currentTime: this.hasAudioTarget ? this.audioTarget.currentTime : 0
      }
      localStorage.setItem("feeeed:audioPlayer", JSON.stringify(data))
    } catch (e) {
      console.error("Failed to save audio player state:", e)
    }
  }

  // === Event Listeners ===
  setupEventListeners() {
    // キュー追加イベントを受信
    document.addEventListener("audio:addToQueue", this.handleAddToQueue.bind(this))
    document.addEventListener("audio:addAllToQueue", this.handleAddAllToQueue.bind(this))
    document.addEventListener("audio:playNow", this.handlePlayNow.bind(this))

    // ページ離脱時に保存
    window.addEventListener("beforeunload", () => this.saveToStorage())

    // Turbo ナビゲーション時にも保存
    document.addEventListener("turbo:before-visit", () => this.saveToStorage())
  }

  handleAddToQueue(event) {
    this.addToQueue(event.detail)
  }

  handleAddAllToQueue(event) {
    const items = event.detail.items || []
    items.forEach(item => this.addToQueue(item, false))
    this.updateUI()
    this.saveToStorage()
  }

  handlePlayNow(event) {
    this.addToQueue(event.detail)
    this.currentIndexValue = this.queueValue.length - 1
    this.loadCurrentTrack()
    this.play()
  }

  // === Queue Management ===
  addToQueue(item, updateUI = true) {
    // 重複チェック
    const exists = this.queueValue.some(q => q.itemId === item.itemId)
    if (exists) return

    this.queueValue = [...this.queueValue, item]

    if (updateUI) {
      this.updateUI()
      this.saveToStorage()
    }

    // 最初のアイテムなら読み込む
    if (this.queueValue.length === 1) {
      this.loadCurrentTrack()
    }
  }

  removeFromQueue(event) {
    const index = parseInt(event.currentTarget.dataset.index, 10)
    const wasPlaying = this.isPlayingValue
    const wasCurrentTrack = index === this.currentIndexValue

    this.queueValue = this.queueValue.filter((_, i) => i !== index)

    if (index < this.currentIndexValue) {
      this.currentIndexValue--
    } else if (wasCurrentTrack) {
      if (this.currentIndexValue >= this.queueValue.length) {
        this.currentIndexValue = Math.max(0, this.queueValue.length - 1)
      }
      this.loadCurrentTrack()
      if (wasPlaying && this.queueValue.length > 0) {
        this.play()
      }
    }

    this.updateUI()
    this.saveToStorage()
  }

  clearQueue() {
    this.pause()
    this.queueValue = []
    this.currentIndexValue = 0
    this.updateUI()
    this.saveToStorage()
  }

  // === Playback Control ===
  loadCurrentTrack() {
    if (!this.hasAudioTarget || this.queueValue.length === 0) return

    const current = this.queueValue[this.currentIndexValue]
    if (!current) return

    this.audioTarget.src = current.url
    this.audioTarget.playbackRate = this.playbackRateValue

    if (this.pendingSeek) {
      this.audioTarget.currentTime = this.pendingSeek
      this.pendingSeek = null
    }

    this.updateUI()
  }

  toggle() {
    if (this.isPlayingValue) {
      this.pause()
    } else {
      this.play()
    }
  }

  play() {
    if (!this.hasAudioTarget || this.queueValue.length === 0) return

    if (!this.audioTarget.src) {
      this.loadCurrentTrack()
    }

    this.audioTarget.play().then(() => {
      this.isPlayingValue = true
      this.updatePlayButton()
    }).catch(e => {
      console.error("Play failed:", e)
    })
  }

  pause() {
    if (!this.hasAudioTarget) return
    this.audioTarget.pause()
    this.isPlayingValue = false
    this.updatePlayButton()
  }

  skipBackward() {
    if (!this.hasAudioTarget) return
    this.audioTarget.currentTime = Math.max(0, this.audioTarget.currentTime - 15)
  }

  skipForward() {
    if (!this.hasAudioTarget) return
    this.audioTarget.currentTime += 30
  }

  previous() {
    if (this.currentIndexValue > 0) {
      this.currentIndexValue--
      this.loadCurrentTrack()
      this.play()
    }
  }

  next() {
    if (this.currentIndexValue < this.queueValue.length - 1) {
      this.currentIndexValue++
      this.loadCurrentTrack()
      this.play()
    } else {
      // キュー終了
      this.pause()
    }
  }

  playAt(event) {
    const index = parseInt(event.currentTarget.dataset.index, 10)
    this.currentIndexValue = index
    this.loadCurrentTrack()
    this.play()
  }

  // === Speed Control ===
  cycleSpeed() {
    const speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
    const currentIdx = speeds.indexOf(this.playbackRateValue)
    const nextIdx = (currentIdx + 1) % speeds.length
    this.playbackRateValue = speeds[nextIdx]

    if (this.hasAudioTarget) {
      this.audioTarget.playbackRate = this.playbackRateValue
    }

    this.updateSpeedDisplay()
    this.saveToStorage()
  }

  // === Progress ===
  seek(event) {
    if (!this.hasAudioTarget || !this.hasProgressTarget) return

    const rect = this.progressTarget.getBoundingClientRect()
    const percent = (event.clientX - rect.left) / rect.width
    const time = percent * this.audioTarget.duration

    if (!isNaN(time)) {
      this.audioTarget.currentTime = time
    }
  }

  seekMobile(event) {
    if (!this.hasAudioTarget || !this.hasProgressMobileTarget) return

    const rect = this.progressMobileTarget.getBoundingClientRect()
    const percent = (event.clientX - rect.left) / rect.width
    const time = percent * this.audioTarget.duration

    if (!isNaN(time)) {
      this.audioTarget.currentTime = time
    }
  }

  onTimeUpdate() {
    this.updateProgress()
    // 5秒ごとに保存
    if (Math.floor(this.audioTarget.currentTime) % 5 === 0) {
      this.saveToStorage()
    }
  }

  onEnded() {
    this.next()
  }

  onLoadedMetadata() {
    this.updateProgress()
  }

  // === Queue Panel ===
  toggleQueuePanel() {
    if (this.hasQueuePanelTarget) {
      this.queuePanelTarget.classList.toggle("hidden")
    }
  }

  closePlayer() {
    this.clearQueue()
  }

  // === UI Updates ===
  updateUI() {
    this.updateVisibility()
    this.updateTrackInfo()
    this.updateQueueCount()
    this.updateQueueList()
    this.updatePlayButton()
    this.updateSpeedDisplay()
    this.updateProgress()
  }

  updateVisibility() {
    if (this.hasContainerTarget) {
      if (this.queueValue.length === 0) {
        this.containerTarget.classList.add("hidden")
        document.body.classList.remove("audio-player-visible")
      } else {
        this.containerTarget.classList.remove("hidden")
        document.body.classList.add("audio-player-visible")
      }
    }
  }

  updateTrackInfo() {
    const current = this.queueValue[this.currentIndexValue]
    const title = current?.title || ""
    const channelTitle = current?.channelTitle || ""

    if (this.hasTitleTarget) {
      this.titleTarget.textContent = title
    }
    if (this.hasTitleMobileTarget) {
      this.titleMobileTarget.textContent = title
    }
    if (this.hasChannelTarget) {
      this.channelTarget.textContent = channelTitle
    }
    if (this.hasChannelMobileTarget) {
      this.channelMobileTarget.textContent = channelTitle
    }
  }

  updateQueueCount() {
    const count = this.queueValue.length
    if (this.hasQueueCountTarget) {
      this.queueCountTarget.textContent = count
    }
    if (this.hasQueueCountMobileTarget) {
      this.queueCountMobileTarget.textContent = count
    }
  }

  updateQueueList() {
    if (!this.hasQueueListTarget) return

    this.queueListTarget.innerHTML = this.queueValue.map((item, index) => `
      <div class="flex items-center gap-2 p-2 ${index === this.currentIndexValue ? 'bg-blue-100' : 'hover:bg-gray-100'} rounded cursor-pointer group"
           data-action="click->audio-player#playAt"
           data-index="${index}">
        <span class="w-6 text-center text-sm text-gray-500">
          ${index === this.currentIndexValue && this.isPlayingValue ? '▶' : (index + 1)}
        </span>
        <div class="flex-1 min-w-0">
          <div class="text-sm font-medium truncate">${this.escapeHtml(item.title)}</div>
          <div class="text-xs text-gray-500 truncate">${this.escapeHtml(item.channelTitle)}</div>
        </div>
        <button class="opacity-0 group-hover:opacity-100 p-1 text-gray-400 hover:text-red-500"
                data-action="click->audio-player#removeFromQueue:stop"
                data-index="${index}">
          <span class="material-symbols-outlined text-lg">close</span>
        </button>
      </div>
    `).join("")
  }

  updatePlayButton() {
    // デスクトップ用
    this._updatePlayButtonPair(this.playButtonTarget, this.playIconTarget)
    // モバイル用
    this._updatePlayButtonPair(this.playButtonMobileTarget, this.playIconMobileTarget)
  }

  _updatePlayButtonPair(buttonTarget, iconTarget) {
    if (!iconTarget || !buttonTarget) return

    // img タグの場合は data 属性から src を取得、span の場合は textContent を切り替え
    if (iconTarget.tagName === "IMG") {
      const playIcon = buttonTarget.dataset.playIcon
      const pauseIcon = buttonTarget.dataset.pauseIcon
      iconTarget.src = this.isPlayingValue ? pauseIcon : playIcon
      iconTarget.alt = this.isPlayingValue ? "一時停止" : "再生"
      // 一時停止アイコンは中央揃えなので ml-0.5 を外す
      iconTarget.classList.toggle("ml-0.5", !this.isPlayingValue)
    } else {
      iconTarget.textContent = this.isPlayingValue ? "pause" : "play_arrow"
    }
  }

  updateSpeedDisplay() {
    const speedText = `${this.playbackRateValue}x`
    // モバイルは短い表示（1.0x → 1x, 1.5x はそのまま）
    const speedTextMobile = this.playbackRateValue === Math.floor(this.playbackRateValue)
      ? `${Math.floor(this.playbackRateValue)}x`
      : `${this.playbackRateValue}x`

    if (this.hasSpeedTarget) {
      this.speedTarget.textContent = speedText
    }
    if (this.hasSpeedMobileTarget) {
      this.speedMobileTarget.textContent = speedTextMobile
    }
  }

  updateProgress() {
    if (!this.hasAudioTarget) return

    const current = this.audioTarget.currentTime || 0
    const duration = this.audioTarget.duration || 0
    const percent = duration > 0 ? (current / duration) * 100 : 0
    const currentTimeText = this.formatTime(current)
    const durationText = this.formatTime(duration)

    // デスクトップ用
    if (this.hasProgressBarTarget) {
      this.progressBarTarget.style.width = `${percent}%`
    }
    if (this.hasCurrentTimeTarget) {
      this.currentTimeTarget.textContent = currentTimeText
    }
    if (this.hasDurationTarget) {
      this.durationTarget.textContent = durationText
    }

    // モバイル用
    if (this.hasProgressBarMobileTarget) {
      this.progressBarMobileTarget.style.width = `${percent}%`
    }
    if (this.hasCurrentTimeMobileTarget) {
      this.currentTimeMobileTarget.textContent = currentTimeText
    }
    if (this.hasDurationMobileTarget) {
      this.durationMobileTarget.textContent = durationText
    }
  }

  // === Utilities ===
  formatTime(seconds) {
    if (!seconds || isNaN(seconds)) return "0:00"
    const mins = Math.floor(seconds / 60)
    const secs = Math.floor(seconds % 60)
    return `${mins}:${secs.toString().padStart(2, "0")}`
  }

  escapeHtml(text) {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
  }
}
