import SwiftUI
import UIKit

private enum PosterImageCache {
    static let shared = NSCache<NSURL, UIImage>()
}

private struct PosterImageView: View {
    let url: URL?
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "play.tv.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(LunaTheme.accent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: url) { await load() }
    }

    private func load() async {
        image = nil
        guard let url else { return }
        if let cached = PosterImageCache.shared.object(forKey: url as NSURL) {
            image = cached
            return
        }
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 15)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("image/avif,image/webp,image/apng,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if let scheme = url.scheme, let host = url.host {
            request.setValue("\(scheme)://\(host)/", forHTTPHeaderField: "Referer")
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              !Task.isCancelled,
              let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode),
              let loadedImage = UIImage(data: data) else { return }
        PosterImageCache.shared.setObject(loadedImage, forKey: url as NSURL)
        image = loadedImage
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
                .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36,
                       alignment: .topLeading)
                .clipped()
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

    private let columns = Array(repeating: GridItem(.flexible(minimum: 0),
                                                     spacing: 10, alignment: .top), count: 3)

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
