import Foundation

struct PlaybackRecoveryPolicy {
    enum Action: Equatable { case wait, reload, exhausted }
    private(set) var attempts = 0
    private(set) var lastRecoveryAt: TimeInterval = -.infinity
    static let maxAttempts = 3

    mutating func reset() { attempts = 0; lastRecoveryAt = -.infinity }
    mutating func decide(connected: Bool, userWantsPlayback: Bool, stalledFor: TimeInterval,
                         now: TimeInterval) -> Action {
        guard connected, userWantsPlayback, stalledFor >= 8 else { return .wait }
        guard now - lastRecoveryAt >= 8 else { return .wait }
        guard attempts < Self.maxAttempts else { return .exhausted }
        attempts += 1
        lastRecoveryAt = now
        // A different playback source always requires an explicit user choice.
        return .reload
    }
}

enum EpisodeIdentity {
    static func number(_ title: String) -> Int? {
        let value = title.replacingOccurrences(of: " ", with: "")
        let patterns = [#"^第?(\d+)(?:集|话|話|期)$"#, #"^(?:EP|E|Episode)(\d+)$"#, #"^(\d+)$"#]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
                  let range = Range(match.range(at: 1), in: value) else { continue }
            return Int(value[range])
        }
        return nil
    }
    static func matchingIndex(for episode: Episode, in target: [Episode]) -> Int? {
        if let index = target.firstIndex(where: { $0.url == episode.url }) { return index }
        if let number = number(episode.title) {
            let matches = target.indices.filter { self.number(target[$0].title) == number }
            return matches.count == 1 ? matches[0] : nil
        }
        let label = episode.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = target.indices.filter { target[$0].title.trimmingCharacters(in: .whitespacesAndNewlines) == label }
        return !label.isEmpty && matches.count == 1 ? matches[0] : nil
    }
}
