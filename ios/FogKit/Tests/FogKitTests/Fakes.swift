import Foundation
@testable import FogKit

/// A lock-protected value, for state shared with `@Sendable` closures.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
    var current: Value { withLock { $0 } }
}

/// A clock tests advance by hand.
final class FakeClock: Sendable {
    private let now = Locked<TimeInterval>(0)
    func advance(_ seconds: TimeInterval) { now.withLock { $0 += seconds } }
    var read: @Sendable () -> TimeInterval { { [now] in now.current } }
}

/// Answers every GET from a closure and records the URLs asked for.
struct FakeFetcher: HTTPFetching {
    let requests = Locked<[URL]>([])
    let respond: @Sendable (URL) throws -> (status: Int, body: Any)

    init(_ respond: @escaping @Sendable (URL) throws -> (status: Int, body: Any)) {
        self.respond = respond
    }

    func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        requests.withLock { $0.append(url) }
        let (status, body) = try respond(url)
        let data = try JSONSerialization.data(withJSONObject: body, options: [.fragmentsAllowed])
        return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    var requestCount: Int { requests.current.count }
}

extension URL {
    func query(_ name: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }
}

struct UpstreamDown: Error, CustomStringConvertible {
    var description: String { "upstream down" }
}
