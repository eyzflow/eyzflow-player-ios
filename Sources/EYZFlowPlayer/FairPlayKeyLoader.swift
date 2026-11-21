#if os(iOS) || os(tvOS)
import AVFoundation
import EYZFlowPlayerCore
import Foundation

/// FairPlay for one asset, in Apple's `AVContentKeySession` flow:
///
/// 1. The asset is added as a content key recipient before its player item is
///    created, so every `skd://` key the item meets comes here (also while it
///    plays over AirPlay).
/// 2. The application certificate is fetched once (prefetched at setup,
///    awaited by the first key request) and cached.
/// 3. For each key request the SPC is built from the certificate and the
///    content id (the `skd://` URI without its scheme), POSTed raw to the
///    licence URL with the `access-token` header, and the raw CKC handed back.
///
/// Keep the loader for as long as the player item plays: renewals, other
/// renditions and AirPlay ask for keys later.
final class FairPlayKeyLoader: NSObject, AVContentKeySessionDelegate, @unchecked Sendable {
    struct Configuration: Sendable {
        var certificateURL: URL
        var licenseURL: URL
        /// Sent with the certificate and licence requests (`access-token`).
        var headers: [String: String]
    }

    private let configuration: Configuration
    private let urlSession: URLSession
    private let session: AVContentKeySession
    /// The key session's delegate queue; all certificate state lives on it.
    private let queue = DispatchQueue(label: "com.eyzflow.player.fairplay")

    private var certificate: Data?
    private var certificateInFlight = false
    private var certificateWaiters: [(Result<Data, Error>) -> Void] = []

    private let lock = NSLock()
    private var _lastErrorMessage: String?
    private var _onError: (@Sendable (String) -> Void)?

    init(configuration: Configuration, urlSession: URLSession = .shared) {
        self.configuration = configuration
        self.urlSession = urlSession
        session = AVContentKeySession(keySystem: .fairPlayStreaming)
        super.init()
        session.setDelegate(self, queue: queue)
    }

    /// The last FairPlay failure, licence server body included: AVFoundation's
    /// own error for it is generic.
    var lastErrorMessage: String? {
        lock.lock(); defer { lock.unlock() }
        return _lastErrorMessage
    }

    /// Called (on any queue) when a key could not be obtained.
    var onError: (@Sendable (String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onError }
        set { lock.lock(); _onError = newValue; lock.unlock() }
    }

    /// Routes the asset's keys here. Call before creating its `AVPlayerItem`.
    func attach(_ asset: AVURLAsset) {
        session.addContentKeyRecipient(asset)
        queue.async { [self] in
            withCertificate { _ in }
        }
    }

    // MARK: Certificate (on `queue`)

    private func withCertificate(_ completion: @escaping (Result<Data, Error>) -> Void) {
        if let certificate {
            completion(.success(certificate))
            return
        }
        certificateWaiters.append(completion)
        guard !certificateInFlight else { return }
        certificateInFlight = true
        var request = URLRequest(url: configuration.certificateURL)
        for (name, value) in configuration.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        urlSession.dataTask(with: request) { [self] data, response, error in
            let result: Result<Data, Error>
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if let error {
                result = .failure(Self.error("FairPlay certificate request failed: \(error.localizedDescription)"))
            } else if !(200 ... 299).contains(status) {
                result = .failure(Self.error("FairPlay certificate request failed (HTTP \(status))"))
            } else if let data, let certificate = FairPlayLicenseFormat.certificate(from: data) {
                result = .success(certificate)
            } else {
                result = .failure(Self.error("FairPlay certificate request returned no data"))
            }
            queue.async { [self] in
                certificateInFlight = false
                // On failure nothing is cached, so the next key request retries.
                if case .success(let data) = result { certificate = data }
                let waiters = certificateWaiters
                certificateWaiters = []
                waiters.forEach { $0(result) }
            }
        }.resume()
    }

    // MARK: Key requests (on `queue`)

    private func handle(_ keyRequest: AVContentKeyRequest) {
        let request = Unchecked(keyRequest)
        guard let contentID = FairPlayLicenseFormat.contentIdentifier(
            identifier: keyRequest.identifier,
            initializationData: keyRequest.initializationData
        ) else {
            fail(request, "FairPlay key request has no skd:// content identifier")
            return
        }
        withCertificate { [self] result in
            switch result {
            case .failure(let error):
                fail(request, error.localizedDescription)
            case .success(let certificate):
                request.value.makeStreamingContentKeyRequestData(
                    forApp: certificate,
                    contentIdentifier: contentID,
                    options: [AVContentKeyRequestProtocolVersionsKey: [1]]
                ) { [self] spc, error in
                    guard let spc else {
                        fail(request, "FairPlay SPC could not be created: \(error?.localizedDescription ?? "unknown error")")
                        return
                    }
                    requestLicense(spc: spc, for: request)
                }
            }
        }
    }

    private func requestLicense(spc: Data, for keyRequest: Unchecked<AVContentKeyRequest>) {
        var request = URLRequest(url: configuration.licenseURL)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = spc
        for (name, value) in configuration.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        urlSession.dataTask(with: request) { [self] data, response, error in
            if let error {
                fail(keyRequest, "FairPlay licence request failed: \(error.localizedDescription)")
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200 ... 299).contains(status) else {
                // Keep the server's body: the coordinator reads codes such as
                // STREAM_LIMIT, DEVICE_LIMIT or PLAYER_KEY_INVALID from it.
                let body = FairPlayLicenseFormat.bodyText(data)
                fail(keyRequest, "FairPlay licence request failed (HTTP \(status))\(body.isEmpty ? "" : ": \(body)")")
                return
            }
            guard let data, let ckc = FairPlayLicenseFormat.ckc(from: data) else {
                fail(keyRequest, "FairPlay licence response was empty")
                return
            }
            keyRequest.value.processContentKeyResponse(
                AVContentKeyResponse(fairPlayStreamingKeyResponseData: ckc)
            )
        }.resume()
    }

    private func fail(_ keyRequest: Unchecked<AVContentKeyRequest>, _ message: String) {
        lock.lock()
        _lastErrorMessage = message
        let callback = _onError
        lock.unlock()
        keyRequest.value.processContentKeyResponseError(Self.error(message))
        callback?(message)
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "EYZFlowPlayer.FairPlay", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    // MARK: AVContentKeySessionDelegate

    func contentKeySession(_ session: AVContentKeySession, didProvide keyRequest: AVContentKeyRequest) {
        handle(keyRequest)
    }

    func contentKeySession(_ session: AVContentKeySession, didProvideRenewingContentKeyRequest keyRequest: AVContentKeyRequest) {
        handle(keyRequest)
    }

    func contentKeySession(_ session: AVContentKeySession, didProvide keyRequest: AVPersistableContentKeyRequest) {
        // Only for offline keys, which the player never asks for.
        handle(keyRequest)
    }

    func contentKeySession(
        _ session: AVContentKeySession,
        shouldRetry keyRequest: AVContentKeyRequest,
        reason retryReason: AVContentKeyRequest.RetryReason
    ) -> Bool {
        switch retryReason {
        case .timedOut, .receivedResponseWithExpiredLease, .receivedObsoleteContentKey: true
        default: false
        }
    }
}

/// Carries a value AVFoundation hands out on its own queue into the URL
/// session's callbacks, which answer it on that queue's behalf.
struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
#endif
