import Foundation

/// Keeps a stable id for this device, sent with playback sessions and DRM
/// licences so the plan's device limit counts the device once.
public protocol DeviceIDStore: Sendable {
    /// The stored id, created and stored on first use.
    func read() async throws -> String
}

/// An id for the life of the process: for tests, and as the fallback when
/// storage is unavailable (the device then counts again after a restart).
public actor MemoryDeviceIDStore: DeviceIDStore {
    private var id: String?

    public init(_ id: String? = nil) {
        self.id = id
    }

    public func read() -> String {
        if let id { return id }
        let created = newUUIDv4()
        id = created
        return created
    }
}

/// The device id in `UserDefaults` under `eyzflow.deviceId` (the web player's
/// local-storage key, and the Flutter player's shared-preferences key).
public final class UserDefaultsDeviceIDStore: DeviceIDStore, @unchecked Sendable {
    public static let defaultKey = "eyzflow.deviceId"

    public let key: String
    public let suiteName: String?
    private let lock = NSLock()

    /// `suiteName` nil is `UserDefaults.standard`.
    public init(key: String = UserDefaultsDeviceIDStore.defaultKey, suiteName: String? = nil) {
        self.key = key
        self.suiteName = suiteName
    }

    public func read() -> String {
        lock.lock()
        defer { lock.unlock() }
        let defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        if let stored = defaults.string(forKey: key), !stored.isEmpty { return stored }
        let id = newUUIDv4()
        defaults.set(id, forKey: key)
        return id
    }
}

/// A random (version 4) UUID, lower case.
public func newUUIDv4() -> String {
    var generator = SystemRandomNumberGenerator()
    return newUUIDv4(using: &generator)
}

/// A version 4 UUID from `generator`'s bytes.
public func newUUIDv4<G: RandomNumberGenerator>(using generator: inout G) -> String {
    var bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    bytes[6] = (bytes[6] & 0x0f) | 0x40
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    let hex = bytes.map { String(format: "%02x", $0) }.joined()
    func part(_ from: Int, _ to: Int) -> Substring {
        hex[hex.index(hex.startIndex, offsetBy: from)..<hex.index(hex.startIndex, offsetBy: to)]
    }
    return "\(part(0, 8))-\(part(8, 12))-\(part(12, 16))-\(part(16, 20))-\(part(20, 32))"
}
