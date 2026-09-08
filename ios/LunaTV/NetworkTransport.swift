import Foundation

@MainActor
final class NetworkTransport {
    private(set) var snapshot = NetworkSnapshot()
    private(set) var session: URLSession
    private let configuration: URLSessionConfiguration

    static func configuration() -> URLSessionConfiguration {
        let value = URLSessionConfiguration.default
        value.timeoutIntervalForRequest = 6
        value.timeoutIntervalForResource = 12
        value.httpMaximumConnectionsPerHost = 4
        value.requestCachePolicy = .reloadRevalidatingCacheData
        value.allowsCellularAccess = true
        value.allowsExpensiveNetworkAccess = true
        value.allowsConstrainedNetworkAccess = true
        value.waitsForConnectivity = false // UI/cached catalogue remains usable offline.
        // No required interface, proxy dictionary override, trust bypass or VPN control.
        return value
    }

    init(configuration: URLSessionConfiguration? = nil) {
        let configuration = configuration ?? Self.configuration()
        self.configuration = configuration
        session = URLSession(configuration: configuration)
    }

    func update(_ next: NetworkSnapshot) {
        guard next != snapshot else { return }
        snapshot = next
        let previous = session
        session = URLSession(configuration: configuration)
        previous.invalidateAndCancel()
    }

    static func mayRetry(_ error: Error, routeChanged: Bool) -> Bool {
        guard let error = error as? URLError else { return false }
        if error.code == .cancelled { return routeChanged }
        return [.networkConnectionLost, .notConnectedToInternet, .timedOut,
                .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(error.code)
    }

    func data(for input: URLRequest) async throws -> (Data, URLResponse) {
        for attempt in 0...1 {
            try Task.checkCancellation()
            guard snapshot.isConnected else { throw URLError(.notConnectedToInternet) }
            let generation = snapshot.generation
            let attemptedSession = session
            var request = input
            request.timeoutInterval = min(input.timeoutInterval, 6)
            do { return try await attemptedSession.data(for: request) }
            catch {
                try Task.checkCancellation()
                guard attempt == 0, snapshot.isConnected,
                      Self.mayRetry(error, routeChanged: generation != snapshot.generation) else { throw error }
                try await Task.sleep(for: .milliseconds(250))
                // A fresh system-routed pool also recovers VPN/DNS changes that
                // keep the same NWPath. Do not cancel unrelated healthy requests.
                if session === attemptedSession {
                    session = URLSession(configuration: configuration)
                    attemptedSession.finishTasksAndInvalidate()
                }
            }
        }
        throw URLError(.cannotConnectToHost)
    }
    deinit { session.invalidateAndCancel() }
}
