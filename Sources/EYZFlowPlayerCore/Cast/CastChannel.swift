import Foundation

/// The Cast conversation with one device, without the socket: launching the
/// receiver, loading media, transport, heartbeats and the device's status.
/// The socket hands it every byte it reads and sends what it writes.
@MainActor
public final class CastChannel {
    static let connectionNamespace = "urn:x-cast:com.google.cast.tp.connection"
    static let heartbeatNamespace = "urn:x-cast:com.google.cast.tp.heartbeat"
    static let receiverNamespace = "urn:x-cast:com.google.cast.receiver"
    static let mediaNamespace = "urn:x-cast:com.google.cast.media"

    public let appID: String
    private let write: @MainActor (Data) -> Void
    private let scheduler: any PlaybackScheduler

    /// The receiver app is running and listening.
    public var onLaunched: (@MainActor () -> Void)?
    /// The device refused to launch the receiver.
    public var onLaunchError: (@MainActor (String) -> Void)?
    /// Every status the receiver reports, also for changes made on the TV.
    public var onPlayback: (@MainActor (CastPlayback) -> Void)?
    /// A request the receiver refused, as `TYPE / reason / detailedErrorCode`.
    public var onError: (@MainActor (String) -> Void)?
    /// The device closed the connection.
    public var onClose: (@MainActor () -> Void)?

    public private(set) var playback = CastPlayback()
    private var frames = CastFrameBuffer()
    private var requestID = 0
    private var transportID: String?
    private var mediaSessionID: Int?
    private var heartbeat: (any PlaybackTimer)?
    private var closed = false

    public init(
        appID: String,
        scheduler: any PlaybackScheduler = TaskScheduler(),
        write: @escaping @MainActor (Data) -> Void
    ) {
        self.appID = appID
        self.scheduler = scheduler
        self.write = write
    }

    /// Connects to the device and asks it to launch the receiver. Heartbeats
    /// every 5 s from here on.
    public func start() {
        send(Self.connectionNamespace, to: "receiver-0", ["type": "CONNECT"])
        send(Self.receiverNamespace, to: "receiver-0", [
            "type": "LAUNCH", "appId": .string(appID), "requestId": .int(nextRequestID()),
        ])
        heartbeat = scheduler.scheduleRepeating(every: .seconds(5)) { [weak self] in
            self?.send(Self.heartbeatNamespace, to: "receiver-0", ["type": "PING"])
        }
    }

    /// Bytes read from the socket.
    public func receive(_ data: Data) {
        let messages: [CastChannelMessage]
        do {
            messages = try frames.add(data)
        } catch {
            close()
            return
        }
        for message in messages { handle(message) }
    }

    /// Loads `media` on the receiver, playing from its `startAt`.
    public func load(_ media: CastMedia, autoplay: Bool = true) {
        sendMedia([
            "type": "LOAD",
            "requestId": .int(nextRequestID()),
            "autoplay": .bool(autoplay),
            "currentTime": .double(media.startAt.inSecondsDouble),
            "media": media.mediaJSON,
        ])
    }

    public func play() { sendMedia(mediaCommand("PLAY")) }
    public func pause() { sendMedia(mediaCommand("PAUSE")) }
    public func stop() { sendMedia(mediaCommand("STOP")) }

    public func seek(to position: Duration) {
        var command = mediaCommand("SEEK")
        command["currentTime"] = .double(position.inSecondsDouble)
        sendMedia(command)
    }

    /// Closes the conversation (and tells the device). The socket closes too.
    public func close() {
        guard !closed else { return }
        if let transportID {
            send(Self.connectionNamespace, to: transportID, ["type": "CLOSE"])
        }
        send(Self.connectionNamespace, to: "receiver-0", ["type": "CLOSE"])
        shutDown()
    }

    /// The socket closed or failed.
    public func socketClosed() {
        shutDown()
    }

    public var isClosed: Bool { closed }

    // MARK: Messages

    private func handle(_ message: CastChannelMessage) {
        guard let data = message.json, let type = data["type"]?.stringValue else { return }
        switch type {
        case "PING":
            send(Self.heartbeatNamespace, to: message.sourceID, ["type": "PONG"])
        case "RECEIVER_STATUS":
            receiverStatus(data)
        case "MEDIA_STATUS":
            mediaStatus(data)
        case "CLOSE":
            shutDown()
        case "LOAD_FAILED", "LOAD_CANCELLED", "INVALID_REQUEST", "ERROR":
            // `ERROR` is what a web receiver sends when playback fails
            // (detailedErrorCode 905 LOAD_FAILED, 102 MEDIA_SRC_NOT_SUPPORTED).
            let parts = [data["type"], data["reason"], data["detailedErrorCode"]].compactMap { value -> String? in
                guard let value else { return nil }
                if let text = value.stringValue { return text }
                if let number = value.numberValue { return String(Int(number)) }
                return nil
            }
            onError?(parts.joined(separator: " / "))
        case "LAUNCH_ERROR":
            onLaunchError?("Cast LAUNCH_ERROR: \(data["reason"]?.stringValue ?? "unknown")")
        default:
            break
        }
    }

    private func receiverStatus(_ data: [String: JSONValue]) {
        guard transportID == nil,
              let applications = data["status"]?["applications"]?.arrayValue,
              let app = applications.first(where: { $0["appId"]?.stringValue == appID }),
              let transport = app["transportId"]?.stringValue
        else { return }
        transportID = transport
        send(Self.connectionNamespace, to: transport, ["type": "CONNECT"])
        onLaunched?()
        // An initial media status so the state settles.
        sendMedia(["type": "GET_STATUS", "requestId": .int(nextRequestID())])
    }

    private func mediaStatus(_ data: [String: JSONValue]) {
        guard let status = data["status"]?.arrayValue?.first?.objectValue else { return }
        if let id = status["mediaSessionId"]?.numberValue { mediaSessionID = Int(id) }
        playback = playback.updated(with: status)
        onPlayback?(playback)
    }

    // MARK: Sending

    private func nextRequestID() -> Int {
        requestID += 1
        return requestID
    }

    private func mediaCommand(_ type: String) -> [String: JSONValue] {
        var command: [String: JSONValue] = ["type": .string(type), "requestId": .int(nextRequestID())]
        if let mediaSessionID { command["mediaSessionId"] = .int(mediaSessionID) }
        return command
    }

    private func sendMedia(_ data: [String: JSONValue]) {
        guard let transportID else { return }
        send(Self.mediaNamespace, to: transportID, data)
    }

    private func send(_ namespace: String, to destination: String, _ data: [String: JSONValue]) {
        guard !closed else { return }
        let payload = String(decoding: JSONValue.object(data).encoded(), as: UTF8.self)
        write(CastCodec.encodeFrame(CastChannelMessage(
            sourceID: "sender-0",
            destinationID: destination,
            namespace: namespace,
            payload: payload
        )))
    }

    private func shutDown() {
        guard !closed else { return }
        closed = true
        heartbeat?.cancel()
        heartbeat = nil
        onClose?()
    }
}
