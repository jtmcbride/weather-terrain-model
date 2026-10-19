import Foundation

public struct CacheStats: Sendable, Equatable {
    public var entries: Int
    public var hits: Int
    public var misses: Int
    public var staleServes: Int
    public var ttlSeconds: TimeInterval
}

/// A TTL cache with single-flight misses and stale-on-error, for upstream
/// weather responses. Port of backend/app/core/cache.py.
///
/// Open-Meteo and the Aviation Weather Center are free, unauthenticated and
/// rate limited, and the app scrubs a 168-hour timeline. Beyond memoisation:
///
/// * **Single flight.** The play button ticks faster than a cold render, so N
///   concurrent misses must share one upstream call rather than become the
///   burst that trips the rate limiter.
/// * **Stale on error.** An expired entry is kept until it is successfully
///   replaced, and served if the refresh fails: an hour-old forecast beats no
///   forecast.
public actor TtlCache<Key: Hashable & Sendable, Value: Sendable> {
    public typealias Clock = @Sendable () -> TimeInterval

    public let ttlSeconds: TimeInterval
    public let maxEntries: Int
    private let clock: Clock
    private var entries: [Key: (value: Value, storedAt: TimeInterval)] = [:]
    /// Insertion order, oldest first, for eviction.
    private var order: [Key] = []
    private var inFlight: [Key: Task<Value, Error>] = [:]
    private var hits = 0
    private var misses = 0
    private var staleServes = 0

    public init(
        ttlSeconds: TimeInterval,
        maxEntries: Int = 8,
        clock: @escaping Clock = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.ttlSeconds = ttlSeconds
        self.maxEntries = max(1, maxEntries)
        self.clock = clock
    }

    /// A fresh value without fetching, or nil.
    public func peek(_ key: Key) -> Value? { fresh(key) }

    /// How long ago this key was last successfully stored, fresh or not.
    public func ageSeconds(_ key: Key) -> TimeInterval? {
        entries[key].map { clock() - $0.storedAt }
    }

    public func clear() {
        entries.removeAll()
        order.removeAll()
    }

    public func stats() -> CacheStats {
        CacheStats(entries: entries.count, hits: hits, misses: misses, staleServes: staleServes, ttlSeconds: ttlSeconds)
    }

    /// The cached value, or the result of `factory` awaited once across all
    /// concurrent callers for this key.
    public func value(for key: Key, factory: @escaping @Sendable () async throws -> Value) async throws -> Value {
        if let value = fresh(key) {
            hits += 1
            return value
        }
        if let pending = inFlight[key] {
            // Matches the Python, where a caller that waited on the lock and
            // then found the entry filled counts as a hit.
            do {
                let value = try await pending.value
                hits += 1
                return value
            } catch {
                // The shared refresh failed; waiters get the same stale answer
                // as its owner rather than an error the owner swallowed.
                guard let expired = entries[key] else { throw error }
                return expired.value
            }
        }

        misses += 1
        let task = Task<Value, Error> { try await factory() }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        do {
            let value = try await task.value
            store(key, value)
            return value
        } catch {
            guard let expired = entries[key] else { throw error }
            staleServes += 1
            return expired.value
        }
    }

    private func fresh(_ key: Key) -> Value? {
        guard let entry = entries[key], clock() - entry.storedAt <= ttlSeconds else { return nil }
        return entry.value
    }

    private func store(_ key: Key, _ value: Value) {
        if entries[key] == nil {
            while entries.count >= maxEntries, let oldest = order.first {
                order.removeFirst()
                entries[oldest] = nil
            }
            order.append(key)
        }
        entries[key] = (value, clock())
    }
}
