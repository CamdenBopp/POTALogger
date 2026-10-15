import Network
import Foundation

/// Monitors network reachability using NWPathMonitor.
/// Starts immediately at launch and stays active for the app lifetime.
@Observable
final class ConnectivityMonitor {
    static let shared = ConnectivityMonitor()

    private let monitor = NWPathMonitor()
    private let queue   = DispatchQueue(label: "app.connectivity", qos: .utility)

    /// True when the device has a usable network path (Wi-Fi, cellular, etc.).
    private(set) var isOnline = false

    private init() {
        monitor.pathUpdateHandler = { [self] path in
            DispatchQueue.main.async {
                self.isOnline = path.status == .satisfied
            }
        }
        monitor.start(queue: queue)
    }
}
