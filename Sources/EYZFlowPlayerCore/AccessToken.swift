import Foundation

/// The DRM `access-token` header the licence servers read
/// (`/v1/drm/:stream_id/:drm/acquire`): base64 of
/// `{"headers":{"authorization":…},"parameters":{…}}`, as the web player
/// builds it in `drm.ts`.
///
/// `parameters` carries what the licence gate checks: `storefront_id`,
/// `device_id`, `playback_session_id` and `player_token`, plus any the host
/// adds (`source: internal`). Null values are left out.
///
/// Keys are written in sorted order and `/` is not escaped, so for ASCII
/// input with the parameters in sorted order the result is byte for byte the
/// web player's `btoa(JSON.stringify(…))`.
public func buildAccessToken(
    _ authorization: String,
    parameters: [String: JSONValue] = [:]
) -> String {
    let payload: JSONValue = [
        "headers": ["authorization": .string(authorization)],
        "parameters": .object(parameters.filter { !$0.value.isNull }),
    ]
    return payload.encoded().base64EncodedString()
}
