import Foundation
import Network

enum Reachability {
    /// True if a TCP connection to host:port can be opened within the timeout.
    static func check(host: String, port: Int, timeout: TimeInterval = 3) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return false }
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let lock = NSLock()
            var finished = false
            let finish: (Bool) -> Void = { reachable in
                lock.lock()
                defer { lock.unlock() }
                guard !finished else { return }
                finished = true
                connection.cancel()
                continuation.resume(returning: reachable)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .waiting, .cancelled: finish(false)
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    /// First address (in configured order) that answers, e.g. LAN name first, then VPN address.
    static func firstReachable(hosts: [String], port: Int) async -> String? {
        for host in hosts where await check(host: host, port: port) {
            return host
        }
        return nil
    }
}
