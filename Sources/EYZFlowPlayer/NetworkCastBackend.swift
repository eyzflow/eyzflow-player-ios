#if os(iOS)
import EYZFlowPlayerCore
import Foundation
import Network

/// Chromecasts through Apple's Network framework, with no Cast SDK:
/// Bonjour discovery of `_googlecast._tcp` and the Cast protocol over TLS.
///
/// The app's Info.plist needs `NSLocalNetworkUsageDescription` and
/// `NSBonjourServices` with `_googlecast._tcp`; the first scan asks the viewer
/// for the Local Network permission.
@MainActor
public final class NetworkCastBackend: CastBackend {
    public init() {}

    public func discover(timeout: Duration) async throws -> [CastTarget] {
        // Kept for the whole scan: its callbacks hold it weakly.
        let discovery = CastDiscovery()
        let devices = try await discovery.run(timeout: timeout)
        withExtendedLifetime(discovery) {}
        return devices
    }

    public func connect(_ target: CastTarget, appID: String) async throws -> any CastConnection {
        try await NetworkCastConnection.open(target, appID: appID)
    }
}

/// One Bonjour scan. Results carry no address, so each service is resolved
/// with a short TCP connection over IPv4 (an IPv6 link-local address is of no
/// use once its interface is dropped; Chromecasts always have IPv4).
@MainActor
final class CastDiscovery {
    private var browser: NWBrowser?
    private var resolving: [String: NWConnection] = [:]
    private var found: [String: CastTarget] = [:]
    private var failure: (any Error)?

    func run(timeout: Duration) async throws -> [CastTarget] {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_googlecast._tcp", domain: nil), using: parameters)
        self.browser = browser
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                if case .failed(let error) = state { self?.failure = error }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.handle(results) }
        }
        browser.start(queue: .main)
        try? await Task.sleep(for: timeout)
        browser.cancel()
        self.browser = nil
        resolving.values.forEach { $0.cancel() }
        resolving = [:]
        if found.isEmpty, let failure { throw failure }
        return Array(found.values).sorted { $0.name < $1.name }
    }

    private func handle(_ results: Set<NWBrowser.Result>) {
        for result in results {
            guard case .service(let service, _, _, _) = result.endpoint,
                  found[service] == nil, resolving[service] == nil else { continue }
            var friendlyName: String?
            var model: String?
            if case .bonjour(let txt) = result.metadata {
                friendlyName = txt["fn"]
                model = txt["md"]
            }
            let parameters = NWParameters.tcp
            if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                ip.version = .v4
            }
            let connection = NWConnection(to: result.endpoint, using: parameters)
            resolving[service] = connection
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                MainActor.assumeIsolated {
                    guard let self, let connection else { return }
                    switch state {
                    case .ready:
                        if case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint {
                            self.found[service] = CastTarget(
                                id: service,
                                name: friendlyName ?? service,
                                model: model,
                                host: Self.address(host),
                                port: Int(port.rawValue)
                            )
                        }
                        connection.cancel()
                        self.resolving[service] = nil
                    case .failed, .cancelled:
                        self.resolving[service] = nil
                    default:
                        break
                    }
                }
            }
            connection.start(queue: .main)
        }
    }

    /// "192.168.1.252%en0" → "192.168.1.252".
    private static func address(_ host: NWEndpoint.Host) -> String {
        let text: String
        switch host {
        case .ipv4(let address): text = "\(address)"
        case .ipv6(let address): text = "\(address)"
        case .name(let name, _): text = name
        @unknown default: text = "\(host)"
        }
        return text.split(separator: "%").first.map(String.init) ?? text
    }
}

enum CastConnectError: Error, CustomStringConvertible {
    case timedOut
    case closed
    case launch(String)

    var description: String {
        switch self {
        case .timedOut: "Cast connection timed out"
        case .closed: "Cast device closed the connection"
        case .launch(let reason): reason
        }
    }
}

/// A TLS connection to one device with the receiver launched.
@MainActor
final class NetworkCastConnection: CastConnection {
    var onPlayback: (@MainActor (CastPlayback) -> Void)?
    var onError: (@MainActor (String) -> Void)?
    var onClose: (@MainActor () -> Void)?

    private let connection: NWConnection
    private var channel: CastChannel!

    private init(_ connection: NWConnection) {
        self.connection = connection
    }

    /// Connects, launches `appID` and returns once the receiver runs.
    static func open(_ target: CastTarget, appID: String, timeout: Duration = .seconds(10)) async throws -> NetworkCastConnection {
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: target.port)) else { throw CastConnectError.closed }
        let tls = NWProtocolTLS.Options()
        // Cast devices present self-signed certificates by design.
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, .main)
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Int(timeout.inSecondsDouble)
        let connection = NWConnection(host: NWEndpoint.Host(target.host), port: port, using: NWParameters(tls: tls, tcp: tcp))
        let cast = NetworkCastConnection(connection)
        try await cast.start(appID: appID, timeout: timeout)
        return cast
    }

    private func start(appID: String, timeout: Duration) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            var pending: CheckedContinuation<Void, any Error>? = continuation
            let finish: @MainActor (Result<Void, any Error>) -> Void = { [weak self] result in
                guard let resume = pending else { return }
                pending = nil
                if case .failure = result { self?.shutDown() }
                resume.resume(with: result)
            }
            channel = CastChannel(appID: appID) { [weak self] data in self?.write(data) }
            channel.onLaunched = { finish(.success(())) }
            channel.onLaunchError = { reason in finish(.failure(CastConnectError.launch(reason))) }
            channel.onPlayback = { [weak self] playback in self?.onPlayback?(playback) }
            channel.onError = { [weak self] reason in self?.onError?(reason) }
            channel.onClose = { [weak self] in
                finish(.failure(CastConnectError.closed))
                self?.connection.cancel()
                self?.onClose?()
            }
            connection.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.channel.start()
                        self.receiveLoop()
                    case .failed(let error):
                        finish(.failure(error))
                        self.channel.socketClosed()
                    case .cancelled:
                        self.channel.socketClosed()
                    default:
                        break
                    }
                }
            }
            connection.start(queue: .main)
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                finish(.failure(CastConnectError.timedOut))
            }
        }
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data, !data.isEmpty { self.channel.receive(data) }
                if isComplete || error != nil {
                    self.channel.socketClosed()
                } else {
                    self.receiveLoop()
                }
            }
        }
    }

    private func write(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard error != nil else { return }
            MainActor.assumeIsolated { self?.channel.socketClosed() }
        })
    }

    func load(_ media: CastMedia) { channel.load(media) }
    func play() { channel.play() }
    func pause() { channel.pause() }
    func seek(to position: Duration) { channel.seek(to: position) }

    func stop() {
        channel.stop()
        channel.close()
        connection.cancel()
    }

    private func shutDown() {
        channel?.close()
        connection.cancel()
    }
}
#endif
