import SwiftUI

enum EpisodePagination {
    static let size = 50
    static func group(for index: Int, count: Int) -> Int {
        max(0, min(index, max(0, count - 1))) / size
    }
    static func ranges(count: Int) -> [Range<Int>] {
        guard count > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map { $0..<min($0 + size, count) }
    }
}

struct EpisodeGridView: View {
    let episodes: [Episode]
    var currentIndex: Int = 0
    let onSelect: (Episode) -> Void
    @State private var selectedGroup = 0

    private var ranges: [Range<Int>] { EpisodePagination.ranges(count: episodes.count) }
    private var visibleIndices: [Int] {
        guard !ranges.isEmpty else { return [] }
        return Array(ranges[min(selectedGroup, ranges.count - 1)])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if ranges.count > 1 {
                ScrollViewReader { reader in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(ranges.indices, id: \.self) { index in
                                let range = ranges[index]
                                Button("\(range.lowerBound + 1)–\(range.upperBound)") { selectedGroup = index }
                                    .buttonStyle(.bordered)
                                    .tint(index == selectedGroup ? LunaTheme.accent : LunaTheme.secondaryText)
                                    .frame(minHeight: 44)
                                    .id(index)
                            }
                        }
                    }
                    .onChange(of: selectedGroup) { value in reader.scrollTo(value, anchor: .center) }
                    .onAppear { reader.scrollTo(selectedGroup, anchor: .center) }
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 10)], spacing: 10) {
                ForEach(visibleIndices, id: \.self) { index in
                    let episode = episodes[index]
                    Button(episode.title) { onSelect(episode) }
                        .buttonStyle(.bordered)
                        .tint(episode.index == currentIndex ? LunaTheme.accent : LunaTheme.secondaryText)
                        .frame(minHeight: 44)
                }
            }
        }
        .onAppear { selectedGroup = EpisodePagination.group(for: currentIndex, count: episodes.count) }
        .onChange(of: currentIndex) { value in selectedGroup = EpisodePagination.group(for: value, count: episodes.count) }
        .onChange(of: episodes.count) { count in selectedGroup = min(selectedGroup, EpisodePagination.group(for: max(0, count - 1), count: count)) }
    }
}
