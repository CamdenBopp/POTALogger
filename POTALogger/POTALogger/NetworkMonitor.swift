import Foundation

// MARK: - Network Monitor

@Observable
final class NetworkMonitor {
    static let shared = NetworkMonitor()
    private init() {}

    private(set) var entries: [(url: String, date: Date)] = []

    @MainActor
    func record(url: URL?) {
        guard let urlString = url?.absoluteString else { return }
        entries.append((url: urlString, date: .now))
        if entries.count > 500 { entries.removeFirst() }
    }

    @MainActor
    func clear() { entries = [] }

    func enable() {
        URLProtocol.registerClass(DebugURLProtocol.self)
    }

    func disable() {
        URLProtocol.unregisterClass(DebugURLProtocol.self)
    }
}

// MARK: - URL Protocol

/// Intercepts all URLSession.shared requests, logs the URL, then passes the request through.
final class DebugURLProtocol: URLProtocol {
    private static let markerKey = "DebugURLProtocolHandled"
    // Dedicated session so forwarded requests never re-enter DebugURLProtocol.
    // URLProtocol.registerClass only affects URLSession.shared; sessions created from a
    // fresh URLSessionConfiguration do not inherit registered protocol classes.
    private static let forwardingSession = URLSession(configuration: .default)
    private var forwardTask: URLSessionDataTask?
    private var recordingTask: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool {
        URLProtocol.property(forKey: markerKey, in: request) == nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        recordingTask = Task { await NetworkMonitor.shared.record(url: request.url) }

        guard let mutable = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else { return }
        URLProtocol.setProperty(true, forKey: Self.markerKey, in: mutable)

        forwardTask = Self.forwardingSession.dataTask(with: mutable as URLRequest) { [weak self] data, response, error in
            guard let self else { return }
            if let response {
                self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            if let data {
                self.client?.urlProtocol(self, didLoad: data)
            }
            if let error {
                self.client?.urlProtocol(self, didFailWithError: error)
            } else {
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
        forwardTask?.resume()
    }

    override func stopLoading() {
        recordingTask?.cancel()
        forwardTask?.cancel()
    }
}
