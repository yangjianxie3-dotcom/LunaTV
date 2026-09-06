import AVFoundation
import AVKit
import SwiftUI
import UIKit

enum PlayerDisplayMode: Equatable {
    case standard
    case fullscreen

    var isFullscreen: Bool { self == .fullscreen }
    var buttonTitle: String { isFullscreen ? "退出全屏" : "全屏" }
    var buttonIcon: String {
        isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
    }
}

@MainActor
private enum PlayerOrientationController {
    static func request(_ orientations: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        scene.windows.first(where: \.isKeyWindow)?.rootViewController?
            .setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientations)) { _ in }
    }
}

@MainActor
final class PlayerController: ObservableObject {
    @Published private(set) var sourceIndex: Int
    @Published private(set) var episodeIndex: Int
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    @Published var errorMessage: String?

    let player = AVPlayer()
    let item: CatalogItem
    let sources: [PlaybackSource]

    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var completionObserver: NSObjectProtocol?
    private var failedSources = Set<Int>()

    init(item: CatalogItem, sources: [PlaybackSource], sourceIndex: Int, episodeIndex: Int) {
        self.item = item
        self.sources = sources
        self.sourceIndex = max(0, min(sources.count - 1, sourceIndex))
        self.episodeIndex = max(0, episodeIndex)
        installTimeObserver()
    }

    var source: PlaybackSource? {
        sources.indices.contains(sourceIndex) ? sources[sourceIndex] : nil
    }

    var episode: Episode? {
        guard let source, source.episodes.indices.contains(episodeIndex) else { return nil }
        return source.episodes[episodeIndex]
    }

    func start(resumeAt: Double) {
        replaceCurrentItem(resumeAt: resumeAt)
    }

    func togglePlayback() {
        if player.timeControlStatus == .playing { player.pause() }
        else { player.play() }
        isPlaying = player.timeControlStatus == .playing
    }

    func seek(to seconds: Double) {
        let target = max(0, min(duration > 0 ? duration : seconds, seconds))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        position = target
    }

    func seek(by seconds: Double) { seek(to: position + seconds) }

    func selectEpisode(_ index: Int, resumeAt: Double = 0) {
        guard let source, source.episodes.indices.contains(index) else { return }
        episodeIndex = index
        failedSources.removeAll()
        replaceCurrentItem(resumeAt: resumeAt)
    }

    func selectSource(_ index: Int, resumeAt: Double = 0) {
        guard sources.indices.contains(index), sources[index].episodes.indices.contains(episodeIndex) else { return }
        sourceIndex = index
        failedSources.removeAll()
        replaceCurrentItem(resumeAt: resumeAt)
    }

    func previousEpisode() { selectEpisode(episodeIndex - 1) }
    func nextEpisode() { selectEpisode(episodeIndex + 1) }

    func stop() { player.pause() }

    private func replaceCurrentItem(resumeAt: Double) {
        guard let episode else {
            errorMessage = "当前线路没有这一集"
            return
        }
        statusObserver = nil
        if let completionObserver { NotificationCenter.default.removeObserver(completionObserver) }
        let playerItem = AVPlayerItem(url: episode.url)
        player.replaceCurrentItem(with: playerItem)
        statusObserver = playerItem.observe(\.status, options: [.new]) { [weak self] observed, _ in
            Task { @MainActor in
                guard let self else { return }
                if observed.status == .failed { self.tryNextSource() }
            }
        }
        completionObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: playerItem, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let source = self.source, self.episodeIndex + 1 < source.episodes.count {
                    self.nextEpisode()
                } else {
                    self.isPlaying = false
                }
            }
        }
        if resumeAt > 10 {
            player.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600))
        }
        errorMessage = nil
        player.play()
        isPlaying = true
    }

    private func tryNextSource() {
        failedSources.insert(sourceIndex)
        let currentLanguage = source?.language
        let sameLanguage = sources.indices.first(where: {
            !failedSources.contains($0) && sources[$0].language == currentLanguage
                && sources[$0].episodes.indices.contains(episodeIndex)
        })
        let anyLanguage = sources.indices.first(where: {
            !failedSources.contains($0) && sources[$0].episodes.indices.contains(episodeIndex)
        })
        guard let next = sameLanguage ?? anyLanguage else {
            errorMessage = "所有可用线路均播放失败"
            isPlaying = false
            return
        }
        sourceIndex = next
        replaceCurrentItem(resumeAt: position)
    }

    private func installTimeObserver() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
                                                      queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.position = max(0, time.seconds.isFinite ? time.seconds : 0)
                let seconds = self.player.currentItem?.duration.seconds ?? 0
                self.duration = seconds.isFinite ? max(0, seconds) : 0
                self.isPlaying = self.player.timeControlStatus == .playing
            }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let completionObserver { NotificationCenter.default.removeObserver(completionObserver) }
    }
}

struct PlayerSurface: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = false
        controller.videoGravity = .resizeAspect
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        controller.player = player
        controller.videoGravity = .resizeAspect
    }
}

struct PlayerView: View {
    @EnvironmentObject private var persistence: PersistenceStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller: PlayerController
    @State private var showControls = true
    @State private var showEpisodes = false
    @State private var showSources = false
    @State private var displayMode: PlayerDisplayMode = .standard

    init(item: CatalogItem, sources: [PlaybackSource], initialSourceIndex: Int, initialEpisodeIndex: Int) {
        _controller = StateObject(wrappedValue: PlayerController(item: item, sources: sources,
                                                                  sourceIndex: initialSourceIndex,
                                                                  episodeIndex: initialEpisodeIndex))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerSurface(player: controller.player)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.18)) { showControls.toggle() }
                }

            if showControls { controls }
            if let error = controller.errorMessage {
                Text(error)
                    .padding()
                    .background(Color(red: 0, green: 0, blue: 0, opacity: 0.8), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            let resume = controller.episode.map { persistence.resumePosition(for: $0.url) } ?? 0
            controller.start(resumeAt: resume)
        }
        .onDisappear {
            saveProgress()
            controller.stop()
            displayMode = .standard
            PlayerOrientationController.request(.portrait)
        }
        .onChange(of: scenePhase) { phase in
            if phase != .active { saveProgress() }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                if controller.isPlaying { saveProgress() }
            }
        }
        .task(id: showControls) {
            guard showControls else { return }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.18)) { showControls = false }
        }
        .sheet(isPresented: $showEpisodes) { episodeSheet }
        .sheet(isPresented: $showSources) { sourceSheet }
    }

    private var controls: some View {
        VStack {
            HStack {
                Button {
                    leavePlayer()
                } label: { Label("返回", systemImage: "chevron.down") }
                Spacer()
                VStack(alignment: .trailing) {
                    Text(controller.item.title).font(.headline)
                    Text(controller.episode?.title ?? "").font(.caption)
                }
            }
            .padding()
            .background(Color(red: 0, green: 0, blue: 0, opacity: 0.58))

            Spacer()

            VStack(spacing: 12) {
                Slider(value: Binding(get: { controller.position }, set: { controller.seek(to: $0) }),
                       in: 0...max(1, controller.duration))
                    .tint(LunaTheme.accent)
                HStack {
                    Text(format(controller.position))
                    Spacer()
                    Text(format(controller.duration))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color(red: 1, green: 1, blue: 1, opacity: 0.75))

                playbackButtons
            }
            .padding()
            .background(Color(red: 0, green: 0, blue: 0, opacity: 0.72))
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var playbackButtons: some View {
        if displayMode.isFullscreen {
            HStack(spacing: 10) {
                primaryPlaybackButtons
                controlButton("选集", "square.grid.3x3.fill") { showEpisodes = true }
                controlButton("线路", "point.3.connected.trianglepath.dotted") { showSources = true }
                fullscreenButton
            }
        } else {
            VStack(spacing: 10) {
                HStack(spacing: 8) { primaryPlaybackButtons }
                HStack(spacing: 16) {
                    controlButton("选集", "square.grid.3x3.fill") { showEpisodes = true }
                    controlButton("线路", "point.3.connected.trianglepath.dotted") { showSources = true }
                    fullscreenButton
                }
            }
        }
    }

    @ViewBuilder
    private var primaryPlaybackButtons: some View {
        controlButton("上一集", "backward.end.fill", enabled: controller.episodeIndex > 0) {
            saveProgress(); controller.previousEpisode()
        }
        controlButton("快退", "gobackward.10") { controller.seek(by: -10) }
        controlButton(controller.isPlaying ? "暂停" : "播放",
                      controller.isPlaying ? "pause.fill" : "play.fill") {
            controller.togglePlayback()
        }
        controlButton("快进", "goforward.10") { controller.seek(by: 10) }
        controlButton("下一集", "forward.end.fill",
                      enabled: controller.episodeIndex + 1 < (controller.source?.episodes.count ?? 0)) {
            saveProgress(); controller.nextEpisode()
        }
    }

    private var fullscreenButton: some View {
        controlButton(displayMode.buttonTitle, displayMode.buttonIcon) { toggleFullscreen() }
    }

    private func controlButton(_ title: String, _ image: String, enabled: Bool = true,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: image).font(.title3)
                Text(title).font(.caption)
            }
            .frame(minWidth: 58)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }

    private var episodeSheet: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 68), spacing: 10)], spacing: 10) {
                    ForEach(controller.source?.episodes ?? []) { episode in
                        Button(episode.title) {
                            saveProgress()
                            controller.selectEpisode(episode.index,
                                                     resumeAt: persistence.resumePosition(for: episode.url))
                            showEpisodes = false
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(episode.index == controller.episodeIndex ? LunaTheme.accent : LunaTheme.surface)
                    }
                }
                .padding()
            }
            .navigationTitle("快速选集")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private var sourceSheet: some View {
        NavigationStack {
            List(controller.sources.indices, id: \.self) { index in
                let source = controller.sources[index]
                Button {
                    saveProgress()
                    controller.selectSource(index,
                                            resumeAt: source.episodes.indices.contains(controller.episodeIndex)
                                            ? persistence.resumePosition(for: source.episodes[controller.episodeIndex].url) : 0)
                    showSources = false
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("\(source.language) · 线路 \(index + 1) · \(source.streamHealth.title)")
                            Text("\(source.name) · \(sourceSpeedDescription(source)) · \(source.episodes.count) 集")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if index == controller.sourceIndex { Image(systemName: "checkmark.circle.fill") }
                    }
                }
                .disabled(!source.episodes.indices.contains(controller.episodeIndex))
            }
            .navigationTitle("切换播放线路")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private func saveProgress() {
        guard let source = controller.source, let episode = controller.episode else { return }
        persistence.updateHistory(item: controller.item, sourceID: source.id, episode: episode,
                                  position: controller.position, duration: controller.duration)
    }

    private func toggleFullscreen() {
        showControls = true
        if displayMode.isFullscreen {
            displayMode = .standard
            PlayerOrientationController.request(.portrait)
        } else {
            displayMode = .fullscreen
            PlayerOrientationController.request(.landscape)
        }
    }

    private func leavePlayer() {
        saveProgress()
        displayMode = .standard
        PlayerOrientationController.request(.portrait)
        dismiss()
    }

    private func sourceSpeedDescription(_ source: PlaybackSource) -> String {
        let throughput: String
        if let value = source.streamThroughputKilobytesPerSecond {
            throughput = value >= 1_024
                ? String(format: "%.1f MB/s", Double(value) / 1_024)
                : "\(value) KB/s"
        } else {
            throughput = "待测速"
        }
        let latency = source.streamLatencyMilliseconds.map { "\($0) ms" } ?? "-- ms"
        return "\(throughput) · \(latency)"
    }

    private func format(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", value / 3600, (value % 3600) / 60, value % 60)
    }
}
