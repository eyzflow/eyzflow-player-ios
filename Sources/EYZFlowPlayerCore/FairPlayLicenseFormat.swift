import Foundation

/// The EYZFlow FairPlay licence contract (`POST /v1/drm/{id}/fairplay/acquire`):
/// the body is the raw SPC, the answer the raw CKC. Lenient readers accept the
/// base64, `<ckc>` and JSON wrappers other FairPlay servers use.
public enum FairPlayLicenseFormat {
    /// The content identifier for the SPC: the `skd://` URI without its scheme,
    /// as UTF-8. `identifier` is the key request's identifier (a `String` or
    /// `URL`); `initializationData` is read when it is missing.
    public static func contentIdentifier(identifier: Any?, initializationData: Data?) -> Data? {
        var uri: String?
        if let string = identifier as? String {
            uri = string
        } else if let url = identifier as? URL {
            uri = url.absoluteString
        } else if let data = initializationData {
            uri = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16LittleEndian)
        }
        let trimmed = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{0}"))
        guard var value = uri?.trimmingCharacters(in: trimmed), !value.isEmpty else { return nil }
        if let range = value.range(of: "skd://", options: [.caseInsensitive, .anchored]) {
            value.removeSubrange(range)
        }
        guard !value.isEmpty else { return nil }
        return value.data(using: .utf8)
    }

    /// The CKC from a licence answer: raw bytes, or a base64 CKC wrapped in
    /// `<ckc>…</ckc>`, a JSON `{"ckc": …}` or sent bare.
    public static func ckc(from data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else {
            return data // binary CKC
        }
        if text.hasPrefix("<ckc>"), text.hasSuffix("</ckc>") {
            let inner = String(text.dropFirst(5).dropLast(6))
            return Data(base64Encoded: inner, options: .ignoreUnknownCharacters)
        }
        if text.hasPrefix("{"),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let value = (json["ckc"] ?? json["CkcMessage"] ?? json["license"]) as? String
        {
            return Data(base64Encoded: value, options: .ignoreUnknownCharacters)
        }
        if text.count >= 16,
           text.range(of: "^[A-Za-z0-9+/=\\r\\n]+$", options: .regularExpression) != nil,
           let decoded = Data(base64Encoded: text, options: .ignoreUnknownCharacters)
        {
            return decoded
        }
        return data
    }

    /// The application certificate: DER as served, or base64 DER.
    public static func certificate(from data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        if data.first == 0x30 { return data } // DER SEQUENCE
        if let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let decoded = Data(base64Encoded: text, options: .ignoreUnknownCharacters),
            decoded.first == 0x30
        {
            return decoded
        }
        return data
    }

    /// A licence server's error body as text, for the error message: the
    /// coordinator reads codes such as `STREAM_LIMIT` from it.
    public static func bodyText(_ data: Data?) -> String {
        guard let data, !data.isEmpty else { return "" }
        return String(decoding: data.prefix(2000), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
