import Foundation

/// Runs blocking work (processes, keychain, DNS, NetFS) on a GCD queue instead of Swift's
/// cooperative thread pool. That pool has only one thread per CPU core; parallel mounts
/// that wait up to half a minute each would otherwise starve every other async task.
enum Blocking {
    private static let queue = DispatchQueue(label: "DriveDock.blocking", qos: .utility, attributes: .concurrent)

    static func run<T>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    static func run<T>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }
}
