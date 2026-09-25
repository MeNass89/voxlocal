import Foundation

/// Counts failed pairing attempts per peer in a sliding window and locks a peer
/// out for `lockout` seconds once it reaches `maxFailures`. Other peers are unaffected.
///
/// A peer is identified by its remote host (not host:port), so reconnecting from a new
/// ephemeral port does not reset the counter.
///
/// The table holds at most `maxPeers` hosts, like the Python host: expired entries
/// are evicted first, then a new peer is refused while the table is full.
public final class RemotePairingGate {
    private struct Record {
        var failures: [Date] = []
        var lockedUntil: Date?
    }

    public static let maxPeers = 1024

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
        let current = now()
        prune(at: current)
        guard let record = records[peer] else { return records.count >= Self.maxPeers }
        guard let until = record.lockedUntil else { return false }
        return until > current
    }

    public func recordFailure(peer: String) {
        lock.lock(); defer { lock.unlock() }
        let current = now()
        prune(at: current)
        guard records[peer] != nil || records.count < Self.maxPeers else { return }
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
