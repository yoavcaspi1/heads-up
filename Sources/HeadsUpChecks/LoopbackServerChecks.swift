@testable import HeadsUpKit
import Foundation

func loopbackServerTests() async {
    suite("LoopbackServerTests")

    await test("testDeliversCodeFromCallback") {
        let server = LoopbackRedirectServer()
        let port = try server.start()
        defer { server.stop() }

        async let result = server.waitForCode(timeout: 5)
        // Simulate the browser redirect.
        let url = URL(string: "http://127.0.0.1:\(port)/callback?state=s&code=abc123")!
        _ = try await URLSession.shared.data(from: url)
        let got = try await result
        try expectEqual(got.code, "abc123")
        try expectEqual(got.state, "s")
    }

    await test("testAccessDeniedThrows") {
        let server = LoopbackRedirectServer()
        let port = try server.start()
        defer { server.stop() }

        async let code = server.waitForCode(timeout: 5)
        let url = URL(string: "http://127.0.0.1:\(port)/callback?error=access_denied")!
        _ = try await URLSession.shared.data(from: url)
        do {
            _ = try await code
            throw CheckFailure(message: "expected throw")
        } catch let e as LoopbackError {
            try expectEqual(e, .deniedByUser)
        }
    }

    await test("code delivered before wait is not lost") {
        let server = LoopbackRedirectServer()
        let port = try server.start()
        defer { server.stop() }

        // Fire the redirect and await its completion before waitForCode is
        // ever called, so the result must be buffered rather than dropped.
        let url = URL(string: "http://127.0.0.1:\(port)/callback?state=s&code=early42")!
        _ = try await URLSession.shared.data(from: url)

        let got = try await server.waitForCode(timeout: 5)
        try expectEqual(got.code, "early42")
    }

    // The loopback server itself does not validate state, it only reports
    // what arrived: validation lives in GoogleOAuth, which compares the
    // returned state against the one it generated (no network involved, so
    // not exercisable from this network-only check). This proves the state
    // value is captured and delivered intact, mismatched or not, so the
    // caller has something to validate against.
    await test("mismatched state is surfaced") {
        let server = LoopbackRedirectServer()
        let port = try server.start()
        defer { server.stop() }

        async let result = server.waitForCode(timeout: 5)
        let url = URL(string: "http://127.0.0.1:\(port)/callback?state=WRONG&code=x")!
        _ = try await URLSession.shared.data(from: url)
        let got = try await result
        try expectEqual(got.code, "x")
        try expectEqual(got.state, "WRONG")
    }

    await test("testTimeout") {
        let server = LoopbackRedirectServer()
        _ = try server.start()
        defer { server.stop() }
        do {
            _ = try await server.waitForCode(timeout: 0.3)
            throw CheckFailure(message: "expected timeout")
        } catch let e as LoopbackError {
            try expectEqual(e, .timeout)
        }
    }
}
