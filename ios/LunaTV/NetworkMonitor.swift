import Foundation
import Network
import Combine

enum NetworkKind: String, Sendable { case wifi, cellular, wired, system, offline, unknown }

struct NetworkSnapshot: Equatable, Sendable {
    var kind: NetworkKind = .unknown
    var isConnected = true
    var isExpensive = false
    var isConstrained = false
    var generation: UInt = 0

    var title: String {
        switch kind {
        case .wifi: return "Wi-Fi"
        case .cellular: return "移动网络"
        case .wired: return "有线网络"
        case .system: return "系统网络"
        case .offline: return "网络暂时断开"
        case .unknown: return "正在检查网络"
        }
    }
    var symbol: String { kind == .cellular ? "antenna.radiowaves.left.and.right" : (isConnected ? "wifi" : "wifi.slash") }
    var bufferSeconds: Double { isConstrained ? 8 : (isExpensive ? 12 : 20) }
    // Keep the user's VPN/system routing. A .other interface is not proof of VPN
    // and neither cellular subtype nor VPN activation is guessed from NWPath.
    var permitsHomeLAN: Bool { kind != .cellular && isConnected }
}

@MainActor
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()
    @Published private(set) var snapshot = NetworkSnapshot()
    private let monitor: NWPathMonitor
    private let queue = DispatchQueue(label: "LunaTV.NetworkPath")
    private var lastFingerprint: String?

    init(startMonitoring: Bool = true) {
        monitor = NWPathMonitor()
        if startMonitoring {
            monitor.pathUpdateHandler = { [weak self] path in
                let kind: NetworkKind = path.status != .satisfied ? .offline
                    : path.usesInterfaceType(.wifi) ? .wifi
                    : path.usesInterfaceType(.cellular) ? .cellular
                    : path.usesInterfaceType(.wiredEthernet) ? .wired : .system
                let state = NetworkSnapshot(kind: kind, isConnected: path.status == .satisfied,
                                            isExpensive: path.isExpensive, isConstrained: path.isConstrained)
                // In-memory only; never log interface names, IP addresses or VPN configuration.
                let fingerprint = path.availableInterfaces.map { "\($0.type)-\($0.index)" }.sorted().joined(separator: ",")
                    + "|\(path.supportsIPv4)|\(path.supportsIPv6)|\(path.supportsDNS)"
                Task { @MainActor in self?.accept(state, fingerprint: fingerprint) }
            }
            monitor.start(queue: queue)
        }
    }

    func accept(_ state: NetworkSnapshot, fingerprint: String) {
        var value = state
        value.generation = snapshot.generation
        guard value != snapshot || fingerprint != lastFingerprint else { return }
        lastFingerprint = fingerprint
        value.generation &+= 1
        snapshot = value
    }

    func revalidateSystemRoute() {
        // VPN changes do not always produce a distinct NWPath event. Also refresh
        // connection pools on foreground return and on an explicit user retry.
        var value = snapshot
        value.generation &+= 1
        snapshot = value
    }
    deinit { monitor.cancel() }
}
