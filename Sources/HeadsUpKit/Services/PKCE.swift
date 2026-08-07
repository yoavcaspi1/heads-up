import Foundation
import CryptoKit

/// RFC 7636 code verifier + S256 challenge.
struct PKCE {
    let verifier: String
    let challenge: String

    init() {
        var bytes = [UInt8](repeating: 0, count: 64)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        self.verifier = Data(bytes).base64URLEncodedString()
        self.challenge = PKCE.challenge(for: verifier)
    }

    static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }
}

extension Data {
    /// Base64url without padding (RFC 4648 section 5).
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
