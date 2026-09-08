import SwiftUI
import UIKit
import ImageIO

@MainActor
private enum PosterImageCache {
    static let shared: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.totalCostLimit = 32 * 1_024 * 1_024
        cache.countLimit = 100
        return cache
    }()
    static let transport = NetworkTransport()
}

struct PosterImageView: View {
    let url: URL?
    @State private var image: UIImage?
    @State private var loadedURL: URL?
    @ObservedObject private var network = NetworkMonitor.shared

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    LunaTheme.surface
                    Image(systemName: "play.tv.fill").font(.system(size: 34)).foregroundStyle(LunaTheme.accent)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: "\(url?.absoluteString ?? "")|\(network.snapshot.generation)") { await load() }
    }

    private func load() async {
        if loadedURL == url && image != nil { return }
        image = nil
        guard let url else { return }
        loadedURL = url
        if let cached = PosterImageCache.shared.object(forKey: url as NSURL) { image = cached; return }
        PosterImageCache.transport.update(network.snapshot)
        guard network.snapshot.isConnected else { return }
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 6)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        if let scheme = url.scheme, let host = url.host {
            request.setValue("\(scheme)://\(host)/", forHTTPHeaderField: "Referer")
        }
        // Bound both compressed download and decoded cache. Avoid retaining full-size
        // originals for a screen containing many small posters.
        guard let data = try? await Self.download(request, session: PosterImageCache.transport.session),
              !Task.isCancelled,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 640,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return }
        let decoded = UIImage(cgImage: thumbnail)
        PosterImageCache.shared.setObject(decoded, forKey: url as NSURL,
                                          cost: thumbnail.bytesPerRow * thumbnail.height)
        image = decoded
    }

    nonisolated private static func download(_ request: URLRequest, session: URLSession) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              response.expectedContentLength <= 4_194_304 else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > 4_194_304 { throw URLError(.dataLengthExceedsMaximum) }
        }
        return data
    }
}

struct NetworkStatusStrip: View {
    @ObservedObject private var network = NetworkMonitor.shared

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: network.snapshot.symbol)
                .foregroundStyle(network.snapshot.isConnected ? LunaTheme.accent : .orange)
            Text(network.snapshot.title).font(.caption.weight(.semibold))
            Spacer()
            Text(network.snapshot.isConnected
                 ? (network.snapshot.isExpensive ? "计费网络 · 随系统切网" : "跟随系统网络 · 支持切换")
                 : "保留已加载内容，等待恢复")
                .font(.caption2).foregroundStyle(LunaTheme.secondaryText)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(LunaTheme.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

struct CatalogCard: View {
    let item: CatalogItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [LunaTheme.raised, LunaTheme.surface],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(maxWidth: .infinity)
            .aspectRatio(CGSize(width: 2, height: 3), contentMode: .fit)
            .overlay {
                PosterImageView(url: item.posterURL)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .clipped(antialiased: true)
            .overlay(alignment: .topTrailing) {
                if let score = item.score, score > 0 {
                    Text(score, format: .number.precision(.fractionLength(1)))
                        .font(.caption.bold())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.pink, in: Capsule())
                        .padding(7)
                }
            }
            Text(item.title)
                .font(.footnote.weight(.semibold))
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
            Text([item.year, item.region].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(LunaTheme.secondaryText)
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 16, maxHeight: 16, alignment: .leading)
                .clipped()
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel([item.title, item.year, item.region].filter { !$0.isEmpty }.joined(separator: "，"))
    }
}

struct CatalogGrid: View {
    let items: [CatalogItem]

    @Environment(\.dynamicTypeSize) private var typeSize
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 150 : 102), spacing: 10, alignment: .top)]
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
            ForEach(items, id: \.deduplicationKey) { item in
                NavigationLink(value: item) {
                    CatalogCard(item: item)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
                .clipped()
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LoadingStateView: View {
    let title: String

    var body: some View {
        VStack(spacing: 14) {
            ProgressView().tint(LunaTheme.accent)
            Text(title).foregroundStyle(LunaTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }
}

struct EmptyStateView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack")
                .font(.system(size: 42))
                .foregroundStyle(LunaTheme.accent)
            HStack {
                Text(title).font(.title3.bold())
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(LunaTheme.secondaryText)
            }
            Text(message)
                .font(.subheadline)
                .foregroundStyle(LunaTheme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding()
            .frame(maxWidth: .infinity, minHeight: 260)
    }
}

struct CatalogSectionRow: View {
    let title: String
    let items: [CatalogItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.bold())
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(items, id: \.deduplicationKey) { item in
                        NavigationLink(value: item) {
                            CatalogCard(item: item).frame(width: 132)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
