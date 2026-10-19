import CryptoKit
import Foundation

/// JSON files in a directory, one per cache key, stamped with the wall-clock
/// time they were fetched.
///
/// The in-memory `TtlCache` already serves stale data when a refresh fails,
/// but it starts empty on every launch, so a launch during an upstream outage
/// or a 429 had nothing to show. Persisting the same entries lets the app open
/// on the last forecast instantly and keep stale-on-error across launches.
/// The age is wall-clock, unlike the in-memory monotonic clock, because it has
/// to survive a restart; a file stamped in the future is treated as expired.
public struct DiskCache: Sendable {
    public let directory: URL
    private let now: @Sendable () -> Date

    public init(directory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.now = now
    }

    /// `Library/Caches/FogKit/<name>`: the system may purge it under storage
    /// pressure, which is the right contract for weather that ages anyway.
    public static func caches(_ name: String) -> DiskCache {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return DiskCache(directory: base.appendingPathComponent("FogKit").appendingPathComponent(name))
    }

    private struct Envelope<Value: Codable>: Codable {
        var storedAt: Date
        var value: Value
    }

    func load<Key: Encodable, Value: Codable>(_ key: Key, as: Value.Type) -> (value: Value, age: TimeInterval)? {
        guard let url = try? url(for: key),
              let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(Envelope<Value>.self, from: data)
        else { return nil }
        let age = now().timeIntervalSince(envelope.storedAt)
        return (envelope.value, age >= 0 ? age : .infinity)
    }

    func save<Key: Encodable, Value: Codable>(_ key: Key, _ value: Value) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Envelope(storedAt: now(), value: value))
            try data.write(to: url(for: key), options: .atomic)
        } catch {
            // A cache that cannot write is a slower app, not a broken one.
        }
    }

    private func url(for key: some Encodable) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let digest = SHA256.hash(data: try encoder.encode(key))
        let name = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(name).json")
    }
}

/// How a `TtlCache` persists entries. Built from a `DiskCache` for Codable
/// keys and values; `TtlCache` itself stays unconstrained.
public struct CachePersistence<Key: Sendable, Value: Sendable>: Sendable {
    let load: @Sendable (Key) -> (value: Value, age: TimeInterval)?
    let save: @Sendable (Key, Value) -> Void
}

extension CachePersistence where Key: Encodable, Value: Codable {
    public static func disk(_ disk: DiskCache) -> CachePersistence {
        CachePersistence(load: { disk.load($0, as: Value.self) }, save: { disk.save($0, $1) })
    }
}

/// Whether a lookup may go to the network.
public enum FetchPolicy: Sendable {
    /// Fresh cache, else the network, else stale cache.
    case normal
    /// Whatever is cached, however old, and never the network: for drawing the
    /// last forecast the moment the app opens.
    case cacheOnly
}

public struct CacheMiss: Error, CustomStringConvertible {
    public var description: String { "nothing cached yet" }
}
