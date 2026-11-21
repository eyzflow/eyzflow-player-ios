import Foundation

/// One Cast message: the small fixed protobuf
/// `extensions.api.cast_channel.CastMessage`, framed with a 4-byte big-endian
/// length. The schema is small and frozen, so its fields are written by hand:
///
/// ```proto
/// required int32  protocol_version = 1; // 0 = CASTV2_1_0
/// required string source_id        = 2;
/// required string destination_id   = 3;
/// required string namespace        = 4;
/// required PayloadType payload_type = 5; // 0 = STRING
/// optional string payload_utf8     = 6;
/// ```
public struct CastChannelMessage: Sendable, Equatable {
    public var sourceID: String
    public var destinationID: String
    public var namespace: String
    /// A JSON string: every Cast control message is JSON.
    public var payload: String

    public init(sourceID: String, destinationID: String, namespace: String, payload: String) {
        self.sourceID = sourceID
        self.destinationID = destinationID
        self.namespace = namespace
        self.payload = payload
    }

    /// The payload as a JSON object, or nil.
    public var json: [String: JSONValue]? {
        JSONValue.decode(Data(payload.utf8))?.objectValue
    }
}

public enum CastCodecError: Error, Equatable {
    case truncated
    case unsupportedWireType(Int)
}

/// Encodes and decodes framed [`CastChannelMessage`]s.
public enum CastCodec {
    /// `message` as a length-framed CastMessage, ready for the socket.
    public static func encodeFrame(_ message: CastChannelMessage) -> Data {
        var body = Data()
        writeVarintField(&body, 1, 0) // protocol_version CASTV2_1_0
        writeString(&body, 2, message.sourceID)
        writeString(&body, 3, message.destinationID)
        writeString(&body, 4, message.namespace)
        writeVarintField(&body, 5, 0) // payload_type STRING
        writeString(&body, 6, message.payload)
        let length = UInt32(body.count)
        var frame = Data([
            UInt8((length >> 24) & 0xFF), UInt8((length >> 16) & 0xFF),
            UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF),
        ])
        frame.append(body)
        return frame
    }

    /// One unframed CastMessage body.
    public static func decodeBody(_ body: Data) throws -> CastChannelMessage {
        let bytes = [UInt8](body)
        var offset = 0
        var message = CastChannelMessage(sourceID: "", destinationID: "", namespace: "", payload: "")
        while offset < bytes.count {
            let tag = try readVarint(bytes, &offset)
            let field = Int(tag >> 3)
            switch Int(tag & 0x7) {
            case 0:
                _ = try readVarint(bytes, &offset) // protocol_version, payload_type: fixed
            case 2:
                let length = Int(try readVarint(bytes, &offset))
                guard length >= 0, offset + length <= bytes.count else { throw CastCodecError.truncated }
                let text = String(decoding: bytes[offset ..< offset + length], as: UTF8.self)
                offset += length
                switch field {
                case 2: message.sourceID = text
                case 3: message.destinationID = text
                case 4: message.namespace = text
                case 6: message.payload = text
                default: break
                }
            case let wireType:
                throw CastCodecError.unsupportedWireType(wireType)
            }
        }
        return message
    }

    private static func writeVarint(_ out: inout Data, _ value: UInt64) {
        var v = value
        while v >= 0x80 {
            out.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        out.append(UInt8(v))
    }

    private static func writeVarintField(_ out: inout Data, _ field: Int, _ value: UInt64) {
        out.append(UInt8(field << 3)) // wire type 0
        writeVarint(&out, value)
    }

    private static func writeString(_ out: inout Data, _ field: Int, _ value: String) {
        out.append(UInt8(field << 3 | 2)) // length-delimited
        let bytes = Data(value.utf8)
        writeVarint(&out, UInt64(bytes.count))
        out.append(bytes)
    }

    private static func readVarint(_ bytes: [UInt8], _ offset: inout Int) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            guard offset < bytes.count, shift < 64 else { throw CastCodecError.truncated }
            let byte = bytes[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
    }
}

/// Collects socket bytes and returns complete messages: partial frames wait
/// for the rest, several frames in one read all come out.
public struct CastFrameBuffer: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func add(_ chunk: Data) throws -> [CastChannelMessage] {
        buffer.append(chunk)
        var messages: [CastChannelMessage] = []
        while buffer.count >= 4 {
            let bytes = [UInt8](buffer.prefix(4))
            let length = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
            guard buffer.count >= 4 + length else { break }
            let body = Data(buffer.dropFirst(4).prefix(length))
            buffer = Data(buffer.dropFirst(4 + length))
            messages.append(try CastCodec.decodeBody(body))
        }
        return messages
    }
}
