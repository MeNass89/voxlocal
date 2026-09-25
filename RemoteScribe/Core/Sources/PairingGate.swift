import Foundation

/// Counts failed pairing attempts per peer in a sliding window and locks a peer
/// out for `lockout` seconds once it reaches `maxFailures`. Other peers are unaffected.
///
/// A peer is identified by its remote host (not host:port), so reconnecting from a new
/// ephemeral port does not reset the counter.
public final class RemotePairingGate {
    private struct Record {
        var failures: [Date] = []
        var lockedUntil: Date?
    }

    private let maxFailures: Int
    private let window: TimeInterval
    private let lockout: TimeInterval
    private let now: () -> Date
    private let lock = NSLock()
    private var records: [String: Record] = [:]

    public init(maxFailures: Int = 5, window: TimeInterval = 600, lockout: TimeInterval = 60, now: @escaping () -> Date = Date.init) {
        self.maxFailures = max(1, maxFailures)
        self.window = window
        self.lockout = lockout
        self.now = now
    }

    public func isLocked(peer: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let until = records[peer]?.lockedUntil else { return false }
        return until > now()
    }

    public func recordFailure(peer: String) {
        lock.lock(); defer { lock.unlock() }
        let current = now()
        prune(at: current)
        var record = records[peer] ?? Record()
        record.failures = record.failures.filter { current.timeIntervalSince($0) < window }
        record.failures.append(current)
        if record.failures.count >= maxFailures {
            record.failures.removeAll()
            record.lockedUntil = current.addingTimeInterval(lockout)
        }
        records[peer] = record
    }

    public func recordSuccess(peer: String) {
        lock.lock(); defer { lock.unlock() }
        records.removeValue(forKey: peer)
    }

    /// Drops peers with no recent failure and no active lock, so the table stays bounded.
    private func prune(at current: Date) {
        records = records.filter { _, record in
            if let until = record.lockedUntil, until > current { return true }
            return record.failures.contains { current.timeIntervalSince($0) < window }
        }
    }
}
