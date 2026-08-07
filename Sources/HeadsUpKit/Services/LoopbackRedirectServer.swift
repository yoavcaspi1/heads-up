import Foundation
import Network

enum LoopbackError: Error, Equatable {
    case timeout
    case deniedByUser
    case notStarted
    case malformedRedirect
}

/// The /callback query params the loopback server captured. `state` is
/// carried through unvalidated: the server only reports what Google sent
/// back, the caller (GoogleOAuth) is the one that knows the state it
/// generated and must compare it.
struct RedirectResult: Equatable {
    let code: String
    let state: String?
}

/// One-shot HTTP listener on 127.0.0.1 that captures the OAuth authorization
/// code Google redirects to. Only ever bound to loopback, ephemeral port.
///
/// `@unchecked Sendable`: `continuation` and `pendingResult` are only ever
/// read or written under `lock`, so cross-thread access to them is safe.
/// `listener` and `port` are written once each, synchronously, inside
/// `start()`/`stop()`, which callers are expected to invoke from a single
/// owning context (the OAuth flow that owns this instance); they are not
/// touched by the connection-handling closures that run on other queues.
final class LoopbackRedirectServer: @unchecked Sendable {
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var continuation: CheckedContinuation<RedirectResult, Error>?
    // Holds a genuine outcome (code or error) that arrived before waitForCode
    // registered a continuation, so it is not silently dropped. Guarded by
    // the same lock as continuation.
    private var pendingResult: Result<RedirectResult, Error>?
    private let lock = NSLock()

    var redirectURI: String { "http://127.0.0.1:\(port)/callback" }

    func start() throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.start(queue: DispatchQueue(label: "headsup.loopback"))
        _ = ready.wait(timeout: .now() + 3)
        guard let bound = listener.port?.rawValue else {
            throw LoopbackError.notStarted
        }
        self.listener = listener
        self.port = bound
        return bound
    }

    func waitForCode(timeout: TimeInterval) async throws -> RedirectResult {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if let pending = pendingResult {
                pendingResult = nil
                lock.unlock()
                switch pending {
                case .success(let result): cont.resume(returning: result)
                case .failure(let error): cont.resume(throwing: error)
                }
                return
            }
            self.continuation = cont
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.resolve(.failure(LoopbackError.timeout))
            }
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        resolve(.failure(LoopbackError.timeout))
    }

    /// Resolves the pending continuation, if one is registered. When
    /// `canBuffer` is true and nothing is registered yet, the result is
    /// stashed in `pendingResult` for the next `waitForCode` call to pick up
    /// immediately, instead of being dropped. Only genuine outcomes from the
    /// HTTP handler pass `canBuffer: true`; the synthetic timeout injected by
    /// `stop()` and by the timeout timer never buffers, so it cannot poison a
    /// later wait. Idempotent either way: a second resolve after the
    /// continuation (or the buffer slot) has already been consumed is a
    /// harmless no-op.
    private func resolve(_ result: Result<RedirectResult, Error>, canBuffer: Bool = false) {
        lock.lock()
        if let cont = continuation {
            continuation = nil
            lock.unlock()
            switch result {
            case .success(let value): cont.resume(returning: value)
            case .failure(let error): cont.resume(throwing: error)
            }
        } else {
            if canBuffer && pendingResult == nil {
                pendingResult = result
            }
            lock.unlock()
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "headsup.loopback.conn"))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            // First line: "GET /callback?code=...&state=... HTTP/1.1"
            let firstLine = request.split(separator: "\r\n").first.map(String.init) ?? ""
            let parts = firstLine.split(separator: " ")
            let path = parts.count > 1 ? String(parts[1]) : ""
            let comps = URLComponents(string: "http://127.0.0.1\(path)")
            let items = comps?.queryItems ?? []
            let body = "<html><body style=\"font-family:sans-serif;padding:2rem\">Heads Up is connected. You can close this tab.</body></html>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
            guard comps?.path == "/callback" else { return }
            let state = items.first(where: { $0.name == "state" })?.value
            if items.contains(where: { $0.name == "error" }) {
                self.resolve(.failure(LoopbackError.deniedByUser), canBuffer: true)
            } else if let code = items.first(where: { $0.name == "code" })?.value {
                self.resolve(.success(RedirectResult(code: code, state: state)), canBuffer: true)
            } else {
                self.resolve(.failure(LoopbackError.malformedRedirect), canBuffer: true)
            }
        }
    }
}
