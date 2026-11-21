import Foundation

/// Sends the player's EYZFlow requests. [`URLSessionHTTPClient`] in apps; a
/// fake in tests.
public protocol HTTPClient: Sendable {
    /// The response for any status code; throws only when there is none
    /// (offline, timeout, cancelled).
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// [`HTTPClient`] over a `URLSession`.
public struct URLSessionHTTPClient: HTTPClient {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw EYZFlowRequestError.notHTTP(request.url)
        }
        return (data, http)
    }
}

/// A request to EYZFlow could not be made or its answer not read. Refusals
/// with a known code are thrown as [`PlayerLicenseError`] or
/// [`PlaybackLimitError`] instead.
public enum EYZFlowRequestError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The server answered with an unexpected status.
    case http(message: String, url: URL?)
    /// The answer was not what the player expects.
    case format(String)
    /// The endpoint origin and path do not make a URL.
    case invalidURL(String)
    /// The response was not an HTTP one.
    case notHTTP(URL?)
    /// No answer in time.
    case timeout

    public var description: String {
        switch self {
        case .http(let message, let url):
            url.map { "\(message) (\($0.absoluteString))" } ?? message
        case .format(let message): message
        case .invalidURL(let value): "Invalid URL: \(value)"
        case .notHTTP(let url): "Not an HTTP response: \(url?.absoluteString ?? "-")"
        case .timeout: "The request timed out."
        }
    }
}

extension URLRequest {
    static func json(
        _ method: String,
        _ url: URL,
        headers: [String: String] = [:],
        body: JSONValue? = nil
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let body {
            request.httpBody = body.encoded()
        }
        return request
    }
}

extension HTTPURLResponse {
    var isSuccess: Bool { (200..<300).contains(statusCode) }
}
