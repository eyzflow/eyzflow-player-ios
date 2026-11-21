import Foundation
@testable import EYZFlowPlayerCore

/// A request as the fake saw it.
struct SentRequest: Sendable {
    let method: String
    let url: URL
    let headers: [String: String]
    let body: Data?

    /// The path as sent, percent-encoding kept.
    var path: String { URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path }
    var call: String { "\(method) \(path)" }
    var json: JSONValue? { body.flatMap(JSONValue.decode) }
}

struct FakeResponse: Sendable {
    var status: Int
    var body: Data

    init(_ status: Int = 200, _ body: String = "") {
        self.status = status
        self.body = Data(body.utf8)
    }

    static func json(_ value: JSONValue, _ status: Int = 200) -> FakeResponse {
        var response = FakeResponse(status)
        response.body = value.encoded()
        return response
    }
}

struct Offline: Error {}

/// An [`HTTPClient`] answering from a handler and recording every request.
final class FakeHTTPClient: HTTPClient, @unchecked Sendable {
    typealias Handler = @Sendable (SentRequest) async throws -> FakeResponse

    private let lock = NSLock()
    private var _requests: [SentRequest] = []
    private var _handler: Handler

    init(_ handler: @escaping Handler) {
        _handler = handler
    }

    var requests: [SentRequest] { lock.withLock { _requests } }
    var calls: [String] { requests.map(\.call) }

    var handler: Handler {
        get { lock.withLock { _handler } }
        set { lock.withLock { _handler = newValue } }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let sent = SentRequest(
            method: request.httpMethod ?? "GET",
            url: request.url!,
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody
        )
        let handler = lock.withLock {
            _requests.append(sent)
            return _handler
        }
        let response = try await handler(sent)
        return (
            response.body,
            HTTPURLResponse(url: sent.url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        )
    }
}

/// A thread-safe counter / box for `@Sendable` handlers.
final class Box<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value

    init(_ value: Value) { _value = value }

    var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }

    @discardableResult
    func update<T>(_ change: (inout Value) -> T) -> T {
        lock.withLock { change(&_value) }
    }
}

/// A [`PlaybackScheduler`] on a manual clock, like Dart's `fakeAsync`:
/// `advance(by:)` runs every timer due, in order, and waits for each action.
@MainActor
final class ManualScheduler: PlaybackScheduler {
    private final class Entry: PlaybackTimer {
        let id: Int
        var due: Int
        let interval: Int?
        let action: @MainActor () async -> Void
        weak var owner: ManualScheduler?

        init(id: Int, due: Int, interval: Int?, action: @escaping @MainActor () async -> Void) {
            self.id = id
            self.due = due
            self.interval = interval
            self.action = action
        }

        func cancel() { owner?.entries.removeAll { $0.id == id } }
    }

    private(set) var nowMs = 0
    private var entries: [Entry] = []
    private var nextID = 0

    var pendingTimers: Int { entries.count }

    func schedule(after delay: Duration, _ action: @escaping @MainActor () async -> Void) -> any PlaybackTimer {
        add(delay: delay.inMilliseconds, interval: nil, action)
    }

    func scheduleRepeating(every interval: Duration, _ action: @escaping @MainActor () async -> Void) -> any PlaybackTimer {
        add(delay: interval.inMilliseconds, interval: interval.inMilliseconds, action)
    }

    private func add(delay: Int, interval: Int?, _ action: @escaping @MainActor () async -> Void) -> Entry {
        let entry = Entry(id: nextID, due: nowMs + max(delay, 0), interval: interval, action: action)
        entry.owner = self
        nextID += 1
        entries.append(entry)
        return entry
    }

    func advance(by duration: Duration) async {
        let target = nowMs + duration.inMilliseconds
        while let next = entries.filter({ $0.due <= target }).min(by: { ($0.due, $0.id) < ($1.due, $1.id) }) {
            nowMs = next.due
            if let interval = next.interval {
                next.due += max(interval, 1)
            } else {
                entries.removeAll { $0.id == next.id }
            }
            await next.action()
        }
        nowMs = target
    }
}

func seconds(_ value: Double) -> Duration {
    .milliseconds(Int((value * 1000).rounded()))
}

func decodeHeader(_ header: String) -> JSONValue? {
    Data(base64Encoded: header).flatMap(JSONValue.decode)
}

/// A main-actor reference, for state a `@MainActor` closure captures and the
/// test changes afterwards.
@MainActor
final class Ref<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}
