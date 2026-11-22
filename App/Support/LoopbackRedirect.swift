// The loopback end of an OAuth authorization code sign-in (RFC 8252 section 7.3): listens on 127.0.0.1 only (never on
// every interface) at the redirect URI's port, opens the authorize URL in the default browser once listening, and returns
// the request target (`/callback?code=…&state=…`) of the first GET of the redirect path that the caller accepts (it
// carries this sign-in's `state`). That request gets a short "You can close this tab" page; any other request (a
// favicon, another path or method, a wrong `state`) gets a 404 and the wait goes on.
// It stops after that callback, after 5 minutes, or when the waiting task is cancelled (Cancel, the Settings modal
// closing). The request target holds the code and is never logged. The port is never shared (no address reuse): after a
// sign-in that ended, the system holds it for up to a minute (TIME_WAIT), so a bind that finds it in use is tried again
// for that long before the port counts as another app's.

import AppKit
import Network

enum LoopbackRedirect {
    enum Failure: Error, Equatable, CustomStringConvertible {
        /// Another app listens on the port.
        case portInUse(UInt16)
        /// No callback within the time limit.
        case timedOut
        /// The listener failed (the error's text, which never holds a request).
        case listenerFailed(String)

        var description: String {
            switch self {
            case .portInUse(let port):
                "Port \(port) on this Mac is used by another app, so the browser cannot return to Histq. Quit that "
                    + "app and try again, or connect with a token."
            case .timedOut: "The sign-in was not approved in the browser within 5 minutes. Start again."
            case .listenerFailed(let detail): "Histq could not wait for the browser: \(detail)"
            }
        }
    }

    /// Listens on `127.0.0.1:<port>`, opens `url` in the default browser once listening, and returns the request target
    /// of the first GET whose path is `path` and that `accepts` takes. `portBusy` runs when a bind finds the port in use
    /// (it is tried again), `listening` when the browser opens: the caller's status follows. Throws `Failure`, or
    /// `CancellationError` when the task is cancelled.
    static func callback(
        port: UInt16, path: String, opening url: URL, timeout: Duration = .seconds(300),
        portBusy: @escaping @MainActor @Sendable () -> Void = {},
        listening: @escaping @MainActor @Sendable () -> Void = {},
        accepts: @escaping @Sendable (_ target: String) -> Bool
    ) async throws -> String {
        let clock = ContinuousClock()
        let bindDeadline = clock.now + portRelease
        while true {
            do {
                let wait = try Wait(port: port, path: path, url: url, listening: listening, accepts: accepts)
                return try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        wait.start(continuation, timeout: timeout)
                    }
                } onCancel: {
                    wait.finish(.failure(CancellationError()))
                }
            } catch Failure.portInUse where clock.now < bindDeadline {
                // Most likely the last sign-in's port, still in TIME_WAIT: the browser opens once it is free.
                try Task.checkCancellation()
                await portBusy()
                try await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// How long a port in use is tried again: longer than the system holds a closed connection's port (TIME_WAIT).
    private static let portRelease: Duration = .seconds(60)

    /// One wait. Its state is only touched on `queue`.
    private final class Wait: @unchecked Sendable {
        private let queue = DispatchQueue(label: "com.math2it.histq.loopback-redirect")
        private let listener: NWListener
        private let port: UInt16
        private let path: String
        private let url: URL
        private let listening: @MainActor @Sendable () -> Void
        private let accepts: @Sendable (String) -> Bool
        private var continuation: CheckedContinuation<String, any Error>?
        private var connections: [ObjectIdentifier: NWConnection] = [:]
        /// Set once the wait has its outcome: later events are ignored.
        private var finished = false
        /// A cancellation that came before `start`.
        private var early: Result<String, any Error>?

        init(
            port: UInt16, path: String, url: URL, listening: @escaping @MainActor @Sendable () -> Void,
            accepts: @escaping @Sendable (String) -> Bool
        ) throws {
            guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw Failure.listenerFailed("bad port") }
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: endpointPort)
            parameters.acceptLocalOnly = true
            parameters.allowLocalEndpointReuse = false
            do {
                listener = try NWListener(using: parameters)
            } catch {
                throw Self.failure(error, port: port)
            }
            self.port = port
            self.path = path
            self.url = url
            self.listening = listening
            self.accepts = accepts
        }

        func start(_ continuation: CheckedContinuation<String, any Error>, timeout: Duration) {
            queue.async { [self] in
                if let early {
                    continuation.resume(with: early)
                    return
                }
                self.continuation = continuation
                listener.stateUpdateHandler = { [self] state in
                    switch state {
                    case .ready:
                        // A wait cancelled or timed out meanwhile opens nothing.
                        guard !finished else { return }
                        let url = url, listening = listening
                        Task { @MainActor in
                            NSWorkspace.shared.open(url)
                            listening()
                        }
                    case .failed(let error), .waiting(let error):
                        finish(.failure(Self.failure(error, port: port)))
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [self] connection in accept(connection) }
                listener.start(queue: queue)
                queue.asyncAfter(deadline: .now() + .seconds(Int(timeout.components.seconds))) { [self] in
                    finish(.failure(Failure.timedOut))
                }
            }
        }

        /// Ends the wait once (callback, timeout, failure or cancel): stops listening and drops the other connections.
        func finish(_ result: Result<String, any Error>, keeping kept: NWConnection? = nil) {
            queue.async { [self] in
                guard !finished else { return }
                finished = true
                listener.cancel()
                for connection in connections.values where connection !== kept { connection.cancel() }
                connections = [:]
                if let continuation {
                    self.continuation = nil
                    continuation.resume(with: result)
                } else {
                    early = result
                }
            }
        }

        private func accept(_ connection: NWConnection) {
            guard !finished else { return connection.cancel() }
            connections[ObjectIdentifier(connection)] = connection
            connection.start(queue: queue)
            receive(connection, Data())
        }

        /// Reads the request head (up to 16 KB), then answers it.
        private func receive(_ connection: NWConnection, _ head: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [self] data, _, isComplete, error in
                var head = head
                if let data { head.append(data) }
                if head.range(of: Data("\r\n\r\n".utf8)) != nil {
                    answer(connection, head)
                } else if error != nil || isComplete || head.count >= 16_384 || finished {
                    close(connection)
                } else {
                    receive(connection, head)
                }
            }
        }

        /// The callback (a GET of `path` that `accepts` takes) gets the closing page and ends the wait; anything else a
        /// 404.
        private func answer(_ connection: NWConnection, _ head: Data) {
            let line = String(decoding: head.prefix { $0 != UInt8(ascii: "\r") }, as: UTF8.self)
            let parts = line.split(separator: " ")
            let target = parts.count == 3 ? String(parts[1]) : ""
            let isCallback = !finished && parts.first == "GET" && target.hasPrefix("/")
                && target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) == path
                && accepts(target)
            let reply = isCallback ? Self.page : Self.notFound
            connection.send(content: Data(reply.utf8), contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { [self] _ in close(connection) })
            if isCallback { finish(.success(target), keeping: connection) }
        }

        private func close(_ connection: NWConnection) {
            connection.cancel()
            connections[ObjectIdentifier(connection)] = nil
        }

        private static func failure(_ error: any Error, port: UInt16) -> Failure {
            if case .posix(.EADDRINUSE) = error as? NWError { return .portInUse(port) }
            return .listenerFailed(String(describing: error))
        }

        private static let page = response(
            "200 OK", body: "<!doctype html><html><head><meta charset=\"utf-8\"><title>Histq</title></head>"
                + "<body style=\"font: 15px -apple-system, sans-serif; margin: 3em; color-scheme: light dark\">"
                + "<p>You can close this tab and return to Histq.</p></body></html>")
        private static let notFound = response("404 Not Found", body: "Not found")

        private static func response(_ status: String, body: String) -> String {
            "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\n"
                + "Cache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n\(body)"
        }
    }
}
