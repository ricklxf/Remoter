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
    /// Reads the shared secret from AgentConfig, generating + persisting a
    /// fresh random one on first use. Never hardcoded in source — must match
    /// whatever is written into turnserver.conf's static-auth-secret (see
    /// ensureSecret's printed value; sync it there manually for now).
    static func ensureSecret() -> String {
        var cfg = AgentConfig.load()
        if !cfg.turnSecret.isEmpty { return cfg.turnSecret }
        let key = SymmetricKey(size: .bits256)
        let secret = key.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
        cfg.turnSecret = secret
        cfg.save()
        ConnectionLogger.shared.logStep(sessionId: "turn", step: "secret_generated",
            detail: "copy into turnserver.conf's static-auth-secret: \(secret)")
        return secret
    }

    static func generate(ttl: TimeInterval = 3600) -> (username: String, password: String) {
        let secret = ensureSecret()
        let expiry = Int(Date().addingTimeInterval(ttl).timeIntervalSince1970)
        let username = String(expiry)
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(username.utf8), using: key)
        let password = Data(mac).base64EncodedString()
        return (username, password)
    }
}
