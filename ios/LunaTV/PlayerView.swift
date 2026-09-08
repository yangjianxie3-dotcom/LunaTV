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
    @State private var scrubPosition: Double = 0
    @State private var isScrubbing = false

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
            if controller.isBuffering && controller.errorMessage == nil {
                VStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text(controller.statusText).font(.subheadline)
                }
                .padding(18)
                .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
                .allowsHitTesting(false)
            }
            if let error = controller.errorMessage {
                VStack(spacing: 14) {
                    Text(error).font(.subheadline).multilineTextAlignment(.center)
                    HStack {
                        Button("保留进度重试") { controller.retry() }
                        Button("选择线路") { showSources = true }
                    }
                    .buttonStyle(.borderedProminent).tint(LunaTheme.accent)
                }
                .padding(20).frame(maxWidth: 340)
                .background(.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            let resume = controller.episode.map { persistence.resumePosition(item: controller.item, episode: $0) } ?? 0
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
            controller.setForeground(phase == .active)
        }
        .onChange(of: controller.wantsPlayback) { playing in
            if !playing { showControls = true }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                if controller.isPlaying { saveProgress() }
            }
        }
        .task(id: "\(showControls)|\(controller.isPlaying)|\(isScrubbing)|\(showEpisodes)|\(showSources)") {
            guard showControls else { return }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, controller.isPlaying, !isScrubbing,
                  !showEpisodes, !showSources else { return }
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
                    Text(controller.item.title).font(.headline).lineLimit(1)
                    Text(controller.episode?.title ?? "").font(.caption)
                    Text("\(controller.selectedLanguage) · 已缓冲 \(Int(controller.bufferAhead)) 秒")
                        .font(.caption2).foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding()
            .background(Color(red: 0, green: 0, blue: 0, opacity: 0.58))

            Spacer()

            VStack(spacing: 12) {
                Slider(value: Binding(get: { isScrubbing ? scrubPosition : min(controller.position, max(1, controller.duration)) },
                                      set: { scrubPosition = $0 }),
                       in: 0...max(1, controller.duration), onEditingChanged: { editing in
                           if editing { scrubPosition = controller.position }
                           isScrubbing = editing
                           if !editing { controller.seek(to: scrubPosition) }
                       })
                    .tint(LunaTheme.accent)
                    .disabled(controller.duration <= 0)
                    .accessibilityLabel("播放进度")
                HStack {
                    Text(format(isScrubbing ? scrubPosition : controller.position))
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
                speedMenu
                fullscreenButton
            }
        } else {
            VStack(spacing: 10) {
                HStack(spacing: 8) { primaryPlaybackButtons }
                HStack(spacing: 16) {
                    controlButton("选集", "square.grid.3x3.fill") { showEpisodes = true }
                    controlButton("线路", "point.3.connected.trianglepath.dotted") { showSources = true }
                    speedMenu
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
        controlButton(controller.wantsPlayback ? "暂停" : "播放",
                      controller.wantsPlayback ? "pause.fill" : "play.fill") {
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

    private var speedMenu: some View {
        Menu {
            ForEach([Float(0.75), 1, 1.25, 1.5, 2], id: \.self) { rate in
                Button("\(rate.formatted()) 倍速") { controller.setRate(rate) }
            }
        } label: {
            VStack(spacing: 5) {
                Image(systemName: "speedometer").font(.title3)
                Text("\(controller.playbackRate.formatted())×").font(.caption)
            }.frame(minWidth: 44, minHeight: 44)
        }.accessibilityLabel("播放倍速")
    }

    private func controlButton(_ title: String, _ image: String, enabled: Bool = true,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: image).font(.title3)
                Text(title).font(.caption)
            }
            .frame(minWidth: 44, minHeight: 44)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }

    private var episodeSheet: some View {
        NavigationStack {
            ScrollView {
                EpisodeGridView(episodes: controller.source?.episodes ?? [], currentIndex: controller.episodeIndex) { episode in
                    saveProgress()
                    controller.selectEpisode(episode.index,
                        resumeAt: persistence.resumePosition(item: controller.item, episode: episode))
                    showEpisodes = false
                }
                .id(controller.source?.id)
                .padding()
            }
            .navigationTitle("快速选集")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private var sourceSheet: some View {
        NavigationStack {
            List {
                ForEach(Array(Set(controller.sources.map(\.language))).sorted(), id: \.self) { language in
                    Section(language == controller.selectedLanguage ? "\(language) · 当前语种" : language) {
                        ForEach(controller.sources.indices.filter { controller.sources[$0].language == language }, id: \.self) { index in
                            let source = controller.sources[index]
                            let matched = controller.matchingEpisodeIndex(in: index) != nil
                            Button {
                                saveProgress()
                                controller.selectSource(index)
                                showSources = false
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(source.name).font(.subheadline.bold())
                                        Text(matched ? "\(source.streamHealth.title) · \(sourceSpeedDescription(source))"
                                             : "未匹配到当前分集，不自动跳集")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if index == controller.sourceIndex { Image(systemName: "checkmark.circle.fill") }
                                }.padding(.vertical, 6)
                            }
                            .disabled(!matched)
                        }
                    }
                }
                Section {
                    Text("网络恢复只重连当前线路，不会自动换源或切换语种。请选择你要使用的线路；手动切换会保留进度，不同剪辑版本可能需要微调。测速仅代表探测时的网络情况。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("语种与播放线路")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showSources = false } } }
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
