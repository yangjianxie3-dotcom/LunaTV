import AVFoundation
import Combine
import Foundation

@MainActor
final class PlayerController: ObservableObject {
    @Published private(set) var sourceIndex: Int
    @Published private(set) var episodeIndex: Int
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var wantsPlayback = true
    @Published private(set) var isBuffering = false
    @Published private(set) var statusText = "准备播放"
    @Published private(set) var playbackRate: Float = 1
    @Published private(set) var firstProgressSeconds: Double?
    @Published private(set) var recoveryCount = 0
    @Published var errorMessage: String?

    let player = AVPlayer()
    let item: CatalogItem
    let sources: [PlaybackSource]
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var completionObserver: NSObjectProtocol?
    private var stalledObserver: NSObjectProtocol?
    private var networkObserver: AnyCancellable?
    private var audioObservers: [NSObjectProtocol] = []
    private var audioInterrupted = false
    private var watchdog: Task<Void, Never>?
    private var policy = PlaybackRecoveryPolicy()
    private var network: NetworkSnapshot
    private var hasStarted = false
    private var isForeground = true
    private var isSeeking = false
    private var pendingResume: Double?
    private var loadStartedAt: TimeInterval = 0
    private var lastProgressAt: TimeInterval = 0
    private var stableSince: TimeInterval?
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    init(item: CatalogItem, sources: [PlaybackSource], sourceIndex: Int, episodeIndex: Int) {
        self.item = item
        self.sources = sources
        self.sourceIndex = max(0, min(sources.count - 1, sourceIndex))
        self.episodeIndex = max(0, episodeIndex)
        network = NetworkMonitor.shared.snapshot
        player.automaticallyWaitsToMinimizeStalling = true
        installTimeObserver()
        networkObserver = NetworkMonitor.shared.$snapshot.dropFirst().sink { [weak self] state in
            self?.networkChanged(state)
        }
        observeAudioSession()
    }
    var source: PlaybackSource? { sources.indices.contains(sourceIndex) ? sources[sourceIndex] : nil }
    var episode: Episode? {
        guard let source, source.episodes.indices.contains(episodeIndex) else { return nil }
        return source.episodes[episodeIndex]
    }
    var selectedLanguage: String { source?.language ?? "原声" }
    var bufferAhead: Double {
        guard let range = player.currentItem?.loadedTimeRanges.first?.timeRangeValue else { return 0 }
        let ahead = CMTimeGetSeconds(CMTimeRangeGetEnd(range)) - position
        return ahead.isFinite ? max(0, ahead) : 0
    }
    func start(resumeAt: Double) {
        guard !hasStarted else { return }
        hasStarted = true
        wantsPlayback = true
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player.isMuted = false
        player.volume = 1
        replaceCurrentItem(resumeAt: resumeAt)
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                self?.checkStall()
            }
        }
    }
    func togglePlayback() {
        wantsPlayback.toggle()
        if wantsPlayback && !audioInterrupted {
            errorMessage = nil
            lastProgressAt = now
            if player.currentItem?.status == .failed { retry() }
            else { player.playImmediately(atRate: playbackRate) }
        } else {
            player.pause()
            isPlaying = false
            isBuffering = false
            statusText = "已暂停"
        }
    }
    func setRate(_ value: Float) {
        guard [Float(0.75), 1, 1.25, 1.5, 2].contains(value) else { return }
        playbackRate = value
        if wantsPlayback && isForeground && !audioInterrupted { player.rate = value }
    }
    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        let target = max(0, min(duration > 0 ? duration : seconds, seconds))
        isSeeking = true
        position = target
        pendingResume = target
        lastProgressAt = now
        let current = player.currentItem
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: CMTime(seconds: 0.5, preferredTimescale: 600),
                    toleranceAfter: CMTime(seconds: 0.5, preferredTimescale: 600)) { [weak self] completed in
            Task { @MainActor in
                guard let self, self.player.currentItem === current else { return }
                self.isSeeking = false
                if completed { self.pendingResume = nil }
                self.lastProgressAt = self.now
                if self.wantsPlayback && self.isForeground && !self.audioInterrupted { self.player.playImmediately(atRate: self.playbackRate) }
            }
        }
    }
    func seek(by seconds: Double) { seek(to: position + seconds) }
    func selectEpisode(_ index: Int, resumeAt: Double = 0) {
        guard let source, source.episodes.indices.contains(index) else { return }
        episodeIndex = index
        policy.reset()
        wantsPlayback = true
        replaceCurrentItem(resumeAt: resumeAt)
    }
    func matchingEpisodeIndex(in sourceIndex: Int) -> Int? {
        guard sources.indices.contains(sourceIndex), let episode else { return nil }
        return EpisodeIdentity.matchingIndex(for: episode, in: sources[sourceIndex].episodes)
    }
    func selectSource(_ index: Int, resumeAt: Double? = nil) {
        guard let mappedIndex = matchingEpisodeIndex(in: index) else {
            errorMessage = "这条线路未找到相同分集，请手动选择分集"; return
        }
        let resume = resumeAt ?? position
        sourceIndex = index; episodeIndex = mappedIndex
        policy.reset()
        replaceCurrentItem(resumeAt: resume)
    }
    func previousEpisode() { selectEpisode(episodeIndex - 1) }
    func nextEpisode() { selectEpisode(episodeIndex + 1) }
    func retry() {
        policy.reset()
        wantsPlayback = true
        NetworkMonitor.shared.revalidateSystemRoute()
        replaceCurrentItem(resumeAt: position)
    }
    func setForeground(_ value: Bool) {
        isForeground = value
        if !value { player.pause(); isPlaying = false }
        else if wantsPlayback && !audioInterrupted {
            lastProgressAt = now
            if player.currentItem?.status == .failed { replaceCurrentItem(resumeAt: position) }
            else { player.playImmediately(atRate: playbackRate) }
        }
    }
    func stop() {
        hasStarted = false; wantsPlayback = false
        watchdog?.cancel(); watchdog = nil
        player.pause()
    }
    private func configureBuffer(_ playerItem: AVPlayerItem) {
        playerItem.preferredForwardBufferDuration = network.bufferSeconds
        // HLS can adapt rendition; a fixed-bitrate source cannot be transcoded here.
        playerItem.preferredPeakBitRate = network.isConstrained ? 2_000_000 : 0
        playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = false
    }
    private func replaceCurrentItem(resumeAt: Double) {
        guard let episode else { errorMessage = "当前线路没有这一集"; return }
        statusObserver = nil
        if let completionObserver { NotificationCenter.default.removeObserver(completionObserver) }
        if let stalledObserver { NotificationCenter.default.removeObserver(stalledObserver) }
        let playerItem = AVPlayerItem(url: episode.url)
        configureBuffer(playerItem)
        position = max(0, resumeAt.isFinite ? resumeAt : 0)
        pendingResume = position > 0 ? position : nil
        duration = 0; isSeeking = false; stableSince = nil
        firstProgressSeconds = nil; loadStartedAt = now; lastProgressAt = now
        errorMessage = nil; isBuffering = wantsPlayback
        statusText = network.isConnected ? "正在缓冲 · \(selectedLanguage)" : "等待网络恢复，将保留当前进度"
        player.replaceCurrentItem(with: playerItem)
        statusObserver = playerItem.observe(\.status, options: [.initial, .new]) { [weak self] observed, _ in
            Task { @MainActor in
                guard let self, self.hasStarted, self.player.currentItem === observed else { return }
                if observed.status == .readyToPlay {
                    if let resume = self.pendingResume { self.seek(to: resume) }
                    else if self.wantsPlayback && self.isForeground && !self.audioInterrupted { self.player.playImmediately(atRate: self.playbackRate) }
                } else if observed.status == .failed { self.recover(force: true) }
            }
        }
        completionObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                                    object: playerItem, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.hasStarted, self.player.currentItem === playerItem else { return }
                if self.episodeIndex + 1 < (self.source?.episodes.count ?? 0) { self.nextEpisode() }
                else { self.wantsPlayback = false; self.isPlaying = false; self.statusText = "播放结束" }
            }
        }
        stalledObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemPlaybackStalled,
                                                                 object: playerItem, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.player.currentItem === playerItem, self.wantsPlayback else { return }
                self.isBuffering = true
                self.statusText = "缓冲中，正在尝试恢复"
            }
        }
        if wantsPlayback && isForeground && !audioInterrupted && pendingResume == nil { player.playImmediately(atRate: playbackRate) }
    }
    private func networkChanged(_ next: NetworkSnapshot) {
        guard next != network else { return }
        network = next
        if let current = player.currentItem { configureBuffer(current) }
        guard hasStarted else { return }
        policy.reset()
        if !next.isConnected { statusText = "网络已断开，保留进度等待恢复" }
        else if wantsPlayback && !isPlaying {
            statusText = "网络已切换，正在续接"
            // Coalesce route flapping through the watchdog; healthy buffered video
            // is never restarted merely because Wi-Fi/VPN changed.
            lastProgressAt = min(lastProgressAt, now - 5)
        }
    }
    private func checkStall() {
        guard hasStarted, wantsPlayback, isForeground, !audioInterrupted else { return }
        if !network.isConnected {
            isBuffering = !isPlaying
            statusText = "网络已断开，恢复后自动续播"
            return
        }
        if now - lastProgressAt >= 8 { recover() }
    }
    private func recover(force: Bool = false) {
        guard hasStarted, isForeground, !audioInterrupted else { return }
        let action = policy.decide(connected: network.isConnected, userWantsPlayback: wantsPlayback,
                                   stalledFor: force ? 8 : now - lastProgressAt,
                                   now: now)
        switch action {
        case .wait: break
        case .reload:
            recoveryCount += 1
            replaceCurrentItem(resumeAt: position)
            statusText = "正在重新连接，保留播放进度"
        case .exhausted:
            errorMessage = "当前线路重连失败。已保留进度，请重试或自行选择其他线路；不会自动换源。"
            wantsPlayback = false; isBuffering = false; isPlaying = false
            player.pause()
        }
    }
    private func installTimeObserver() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
                                                       queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, self.hasStarted else { return }
                let current = time.seconds
                if !self.isSeeking && self.pendingResume == nil && current.isFinite {
                    if current > self.position + 0.1 {
                        self.lastProgressAt = self.now
                        if self.firstProgressSeconds == nil { self.firstProgressSeconds = self.now - self.loadStartedAt }
                        if self.stableSince == nil { self.stableSince = self.now }
                        if self.now - (self.stableSince ?? self.now) > 20 { self.policy.reset() }
                    }
                    self.position = max(0, current)
                }
                let seconds = self.player.currentItem?.duration.seconds ?? 0
                self.duration = seconds.isFinite ? max(0, seconds) : 0
                self.isPlaying = self.player.timeControlStatus == .playing
                self.isBuffering = self.wantsPlayback && !self.isPlaying
                if self.isPlaying { self.statusText = "\(self.selectedLanguage) · 播放中" }
            }
        }
    }
    private func observeAudioSession() {
        audioObservers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                                                      object: nil, queue: .main) { [weak self] notification in
            let type = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
            let options = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
            Task { @MainActor in
                guard let self, self.hasStarted else { return }
                if type == AVAudioSession.InterruptionType.began.rawValue {
                    self.audioInterrupted = true
                    self.player.pause(); self.isPlaying = false; self.isBuffering = false
                    self.statusText = "通话或系统音频中断，已保留进度"
                } else if type == AVAudioSession.InterruptionType.ended.rawValue {
                    self.audioInterrupted = false
                    if AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
                        && self.wantsPlayback && self.isForeground {
                        self.lastProgressAt = self.now
                        self.player.playImmediately(atRate: self.playbackRate)
                    } else {
                        self.wantsPlayback = false
                        self.statusText = "已暂停，点击播放继续"
                    }
                }
            }
        })
        audioObservers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
                                                                      object: nil, queue: .main) { [weak self] notification in
            let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
            guard reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            Task { @MainActor in
                guard let self, self.hasStarted else { return }
                self.wantsPlayback = false; self.player.pause(); self.isPlaying = false; self.isBuffering = false
                self.statusText = "耳机已断开，已暂停"
            }
        })
    }
    deinit {
        watchdog?.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let completionObserver { NotificationCenter.default.removeObserver(completionObserver) }
        if let stalledObserver { NotificationCenter.default.removeObserver(stalledObserver) }
        for observer in audioObservers { NotificationCenter.default.removeObserver(observer) }
    }
}
