import Foundation

/// The one network seam. `URLSession` in the app; a fake in tests, which run
/// with no network (as the backend's do).
public protocol HTTPFetching: Sendable {
    func get(_ url: URL) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionFetcher: HTTPFetching {
    public let session: URLSession

    public init(timeoutSeconds: TimeInterval = 30) {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeoutSeconds
        // TtlCache is the cache; URLCache revalidating underneath it would
        // only make freshness harder to reason about.
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    public func get(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

/// A non-2xx response. Port of httpx's `raise_for_status`.
public struct HTTPStatusError: Error, CustomStringConvertible {
    public let statusCode: Int
    public let url: URL

    public var description: String { "HTTP \(statusCode) from \(url.host ?? url.absoluteString)" }
}

extension HTTPFetching {
    /// GET and parse JSON, throwing on a non-2xx status.
    func json(_ url: URL) async throws -> Any {
        let (data, response) = try await get(url)
        guard (200..<300).contains(response.statusCode) else {
            throw HTTPStatusError(statusCode: response.statusCode, url: url)
        }
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
}

/// Python's `float(value)` over JSON: numbers, and numeric strings.
func jsonDouble(_ value: Any?) -> Double? {
    switch value {
    case let number as NSNumber:
        return number.doubleValue
    case let text as String:
        return Double(text.trimmingCharacters(in: .whitespaces))
    default:
        return nil
    }
}

/// `"%.5f"`, the coordinate precision both upstream requests use.
func coordinateString(_ value: Double) -> String { String(format: "%.5f", value) }
