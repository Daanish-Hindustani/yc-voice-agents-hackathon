import Foundation
import Network
import os

private let log = Logger(subsystem: "com.cacty", category: "bridge")

/// Minimal loopback HTTP bridge so an out-of-process caller (the
/// Pipecat voice bot) can drive the agent the same way the menu-bar
/// and Fn-PTT surfaces do: hand a natural-language prompt to the
/// `AgentSupervisor`, wait for the worker loop to terminate, and read
/// back the model's final text.
///
/// This is the ONLY external entry point Cacty exposes. It binds to
/// `127.0.0.1` only (never a routable interface), so nothing off-box
/// can reach it.
///
/// Endpoints:
///
///   GET  /health  → `{"ok": true}` — liveness probe; lets the caller
///                   confirm the bridge before sending any task.
///   POST /task    → body `{"prompt": "<task>"}`. Starts the task,
///                   blocks until it succeeds/fails/cancels (or hits
///                   `maxWait`), then returns one of:
///                     {"ok": true,  "text":  "<final agent text>"}
///                     {"ok": false, "error": "<reason>"}
///
/// Synchronous-by-design: one request maps to one completed task, so
/// the voice bot can `await` a single HTTP call and speak the result.
/// Cacty tasks take tens of seconds, so the caller must use a generous
/// client-side timeout (≥ `maxWait`).
public final class LocalTaskServer: @unchecked Sendable {
    private let supervisor: AgentSupervisor
    private let port: NWEndpoint.Port
    private let maxWait: TimeInterval
    private let pollInterval: UInt64 = 500_000_000 // 0.5s in ns
    private let queue = DispatchQueue(label: "com.cacty.bridge")
    private var listener: NWListener?

    /// - Parameters:
    ///   - supervisor: The same supervisor the UI surfaces drive.
    ///   - port: Loopback TCP port. Defaults to 8765; override via the
    ///     `CACTY_BRIDGE_PORT` env var (read by the caller in
    ///     `CactyApp`).
    ///   - maxWait: Hard ceiling on how long a single task may run
    ///     before the bridge gives up waiting and returns a timeout
    ///     error. The task itself keeps running in the supervisor; the
    ///     bridge just stops blocking the HTTP response.
    public init(
        supervisor: AgentSupervisor,
        port: UInt16 = 8765,
        maxWait: TimeInterval = 300
    ) {
        self.supervisor = supervisor
        // Force-unwrap is safe: any UInt16 is a valid port number.
        self.port = NWEndpoint.Port(rawValue: port)!
        self.maxWait = maxWait
    }

    /// Bind and begin accepting connections. Errors are logged, not
    /// thrown — a missing bridge must never crash the app; the UI
    /// surfaces keep working and the caller's `/health` probe simply
    /// fails until the conflict (e.g. port in use) is resolved.
    public func start() {
        let params = NWParameters.tcp
        // Pin the bind address to loopback so the bridge is
        // unreachable from any other host. The port rides along on
        // the endpoint, so we do NOT also pass `on:` to NWListener.
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        params.allowLocalEndpointReuse = true

        do {
            let listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    log.error("bridge listener failed: \(String(describing: error), privacy: .public)")
                }
            }
            listener.start(queue: queue)
            self.listener = listener
            log.info("bridge listening on 127.0.0.1:\(self.port.rawValue, privacy: .public)")
        } catch {
            log.error("bridge failed to start: \(String(describing: error), privacy: .public)")
        }
    }

    /// Stop accepting connections. Used on app teardown.
    public func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, accumulated: Data())
    }

    /// Accumulate bytes until a full HTTP request (headers + any
    /// declared body) is available, then route it. Reads incrementally
    /// because a POST body can span multiple TCP segments.
    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }

            var buffer = accumulated
            if let data { buffer.append(data) }

            if let request = HTTPRequest.parse(buffer) {
                self.route(connection, request)
                return
            }

            if error != nil || isComplete {
                self.respond(connection, status: 400, body: ["ok": false, "error": "bad request"])
                return
            }

            // Headers/body not complete yet — keep reading.
            self.receive(connection, accumulated: buffer)
        }
    }

    private func route(_ connection: NWConnection, _ request: HTTPRequest) {
        switch (request.method, request.path) {
        case ("GET", "/health"):
            respond(connection, status: 200, body: ["ok": true])

        case ("POST", "/task"):
            guard
                let object = try? JSONSerialization.jsonObject(with: request.body),
                let dict = object as? [String: Any],
                let prompt = dict["prompt"] as? String,
                !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                respond(connection, status: 400, body: ["ok": false, "error": "missing 'prompt'"])
                return
            }
            // Run the task and respond once it terminates. The Task
            // hops to the supervisor actor for start + polling; the
            // HTTP write happens back here on completion.
            Task {
                let result = await self.runTask(prompt: prompt)
                self.respond(connection, status: 200, body: result)
            }

        default:
            respond(connection, status: 404, body: ["ok": false, "error": "not found"])
        }
    }

    /// Start a task and poll the supervisor until it reaches a terminal
    /// state. Mirrors `AppCoordinator.watchTask`, but returns the
    /// outcome to the HTTP caller instead of driving UI state.
    private func runTask(prompt: String) async -> [String: Any] {
        let id = await supervisor.startTask(prompt: prompt)
        log.info("bridge started task \(id, privacy: .public)")

        let deadline = Date().addingTimeInterval(maxWait)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: pollInterval)
            switch await supervisor.status(of: id) {
            case .running, .none:
                continue
            case .succeeded(let text):
                return ["ok": true, "text": text]
            case .failed(let reason):
                return ["ok": false, "error": reason]
            case .cancelled:
                return ["ok": false, "error": "cancelled"]
            }
        }

        // Hit the wait ceiling. The task keeps running in the
        // supervisor; we just stop blocking the response.
        return ["ok": false, "error": "timeout after \(Int(maxWait))s"]
    }

    // MARK: - HTTP response

    private func respond(_ connection: NWConnection, status: Int, body: [String: Any]) {
        let payload = (try? JSONSerialization.data(withJSONObject: body))
            ?? Data(#"{"ok":false,"error":"serialization failed"}"#.utf8)

        let head = """
        HTTP/1.1 \(status) \(Self.reason(for: status))\r
        Content-Type: application/json\r
        Content-Length: \(payload.count)\r
        Connection: close\r
        \r

        """
        var response = Data(head.utf8)
        response.append(payload)

        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        default: return "Error"
        }
    }
}

/// The slice of an HTTP/1.1 request the bridge needs: method, path,
/// and the (possibly empty) body. Parsing is intentionally tiny —
/// this server only ever sees requests from our own Python client.
///
/// `internal` (not `private`) so `LocalTaskServerTests` can exercise
/// `parse` directly — it's the one piece of hand-rolled logic here
/// that benefits from deterministic coverage.
struct HTTPRequest {
    let method: String
    let path: String
    let body: Data

    /// Returns `nil` when `raw` does not yet contain a complete
    /// request (headers terminator missing, or fewer body bytes than
    /// `Content-Length` declares), signalling the caller to read more.
    static func parse(_ raw: Data) -> HTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = raw.range(of: separator) else { return nil }

        let headerData = raw[raw.startIndex..<headerEnd.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        // Strip any query string; the bridge routes on path only.
        let path = String(parts[1].split(separator: "?").first ?? parts[1])

        // Find Content-Length (case-insensitive) to know body size.
        var contentLength = 0
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { continue }
            if pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                contentLength = Int(pair[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }

        let bodyStart = headerEnd.upperBound
        let available = raw.distance(from: bodyStart, to: raw.endIndex)
        guard available >= contentLength else { return nil } // need more bytes

        let bodyEnd = raw.index(bodyStart, offsetBy: contentLength)
        let body = Data(raw[bodyStart..<bodyEnd])
        return HTTPRequest(method: method, path: path, body: body)
    }
}
