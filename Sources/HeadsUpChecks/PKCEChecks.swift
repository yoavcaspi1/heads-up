@testable import HeadsUpKit
import Foundation

func pkceTests() async {
    suite("PKCETests")

    await test("testRFC7636AppendixBVector") {
        // Known test vector from RFC 7636 appendix B.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        try expectEqual(PKCE.challenge(for: verifier), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    await test("testGeneratedVerifierShapeAndUniqueness") {
        let a = PKCE(), b = PKCE()
        try expect(a.verifier != b.verifier)
        try expect(a.verifier.count >= 43)
        try expect(a.verifier.count <= 128)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        try expect(a.verifier.unicodeScalars.allSatisfy { allowed.contains($0) })
        try expectEqual(a.challenge, PKCE.challenge(for: a.verifier))
    }
}
