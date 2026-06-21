import Foundation
import CryptoKit

// Ephemeral TURN credentials — the widely-used "REST API" scheme
// (https://datatracker.ietf.org/doc/html/draft-uberti-rtcweb-turn-rest-00),
// also what coturn's `use-auth-secret` expects:
//   username = "<unix-expiry-timestamp>"
//   password = base64(HMAC-SHA1(secret, username))
//
// No long-lived TURN login ever touches the client — a fresh, time-limited
// credential is minted per WebRTC offer. HMAC-SHA1 here is the protocol's
// mandated algorithm (coturn only validates this exact construction), not a
// general-purpose security primitive — the secret itself never leaves this
// process, and each credential only grants relay use for `ttl` seconds.
enum TurnCredentials {
    // 必须和 /opt/homebrew/etc/turnserver.conf 里的 static-auth-secret 完全一致。
    private static let sharedSecret = "8d893c84c551524d6d7b0b3e9d7886a81796021090b38e92745bb0866f0f3633"

    static func generate(ttl: TimeInterval = 3600) -> (username: String, password: String) {
        let expiry = Int(Date().addingTimeInterval(ttl).timeIntervalSince1970)
        let username = String(expiry)
        let key = SymmetricKey(data: Data(sharedSecret.utf8))
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(username.utf8), using: key)
        let password = Data(mac).base64EncodedString()
        return (username, password)
    }
}
