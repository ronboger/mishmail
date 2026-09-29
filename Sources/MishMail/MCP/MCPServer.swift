import Foundation
import Network

/// In-process MCP Streamable HTTP server (JSON-RPC over HTTP/1.1).
///
/// Binds 127.0.0.1 only on an ephemeral port. Single endpoint `POST /mcp`
/// with Bearer auth. Modeled on `OAuthService.startLoopbackListener`.
final class MCPServer: @unchecked Sendable {
    /// Max request size (headers + body). Over this → close without reply.
    static let maxRequestBytes = 2 * 1024 * 1024
    /// A client must finish one request promptly; incomplete connections do
    /// not get to occupy a listener slot indefinitely.
    static let readDeadline: TimeInterval = 10
    /// Keep a slow or abusive client burst from consuming unbounded resources.
    static let maxConcurrentConnections = 16

    private let tools: any MCPToolProvider
    private let serverVersion: String
    private var listener: NWListener?
    private var token: String = ""
    private var activeConnections = 0
    private let queue = DispatchQueue(label: "dev.ronboger.MishMail.mcp", qos: .userInitiated)
    private let lock = NSLock()

    init(tools: any MCPToolProvider, serverVersion: String = MCPRouter.defaultServerVersion) {
        self.tools = tools
        self.serverVersion = serverVersion
    }

    /// Start listening. Returns the bound port.
    ///
    /// `preferredPort` 0 requests an ephemeral port; a fixed port keeps client
    /// configs (Claude Code, Codex, …) valid across app relaunches, at the
    /// cost of failing when something else already holds it.
    @discardableResult
    func start(token: String, preferredPort: UInt16 = 0) throws -> UInt16 {
        lock.lock()
        defer { lock.unlock() }
        if listener != nil { stopUnlocked() }

        self.token = token
        let params = NWParameters.tcp
        let nwPort = NWEndpoint.Port(rawValue: preferredPort) ?? .any
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in
            guard let self, self.reserveConnection() else {
                conn.cancel()
                return
            }
            self.handleConnection(conn)
        }
        // With a fixed port, address-in-use surfaces as .failed (not a thrown
        // init error) and `listener.port` can still echo the requested value,
        // so track failure explicitly and treat it as a bind failure.
        let failed = MCPAtomicFlag()
        listener.stateUpdateHandler = { state in
            if case .failed = state {
                failed.set()
            }
        }
        listener.start(queue: queue)
        self.listener = listener

        var port: UInt16 = 0
        for _ in 0..<100 {
            if failed.isSet { break }
            if case .ready = listener.state, let p = listener.port?.rawValue, p != 0 {
                port = p
                break
            }
            usleep(10_000)
        }
        guard port != 0, !failed.isSet else {
            listener.cancel()
            self.listener = nil
            throw MCPServerError.bindFailed
        }
        return port
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        stopUnlocked()
    }

    private func stopUnlocked() {
        listener?.cancel()
        listener = nil
        token = ""
    }

    // MARK: - Connection handling

    private func reserveConnection() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeConnections < Self.maxConcurrentConnections else { return false }
        activeConnections += 1
        return true
    }

    private func releaseConnection() {
        lock.lock()
        activeConnections = max(0, activeConnections - 1)
        lock.unlock()
    }

    private func handleConnection(_ conn: NWConnection) {
        let state = MCPConnectionState { [weak self] in
            self?.releaseConnection()
        }
        conn.start(queue: queue)
        let deadline = DispatchWorkItem { [weak state] in
            guard state?.finish() == true else { return }
            conn.cancel()
        }
        state.installReadDeadline(deadline)
        queue.asyncAfter(deadline: .now() + Self.readDeadline, execute: deadline)
        accumulate(on: conn, into: Data(), state: state)
    }

    private func accumulate(
        on conn: NWConnection,
        into buffer: Data,
        state: MCPConnectionState
    ) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: Self.maxRequestBytes) {
            [weak self] data, _, isComplete, error in
            guard let self else {
                state.finish()
                conn.cancel()
                return
            }
            guard !state.isFinished else {
                conn.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }

            if buffer.count > Self.maxRequestBytes {
                state.finish()
                conn.cancel()
                return
            }

            if let request = MCPHTTP.parse(buffer) {
                state.cancelReadDeadline()
                self.serve(request, on: conn, state: state)
                return
            }

            if error != nil || isComplete {
                state.finish()
                conn.cancel()
                return
            }
            self.accumulate(on: conn, into: buffer, state: state)
        }
    }

    private func serve(
        _ request: MCPHTTPRequest,
        on conn: NWConnection,
        state: MCPConnectionState
    ) {
        // Path / method gates before auth so probes don't need the token shape.
        guard request.path == "/mcp" else {
            reply(MCPHTTP.response(status: 404, reason: "Not Found"), on: conn, state: state)
            return
        }
        guard request.method.uppercased() == "POST" else {
            // GET /mcp and any other method → 405.
            reply(MCPHTTP.response(status: 405, reason: "Method Not Allowed"), on: conn, state: state)
            return
        }

        lock.lock()
        let expected = token
        lock.unlock()
        guard let presented = MCPHTTP.bearerToken(from: request.headers),
              MCPServerSecurity.constantTimeEqual(presented, expected), !expected.isEmpty else {
            reply(MCPHTTP.response(status: 401, reason: "Unauthorized"), on: conn, state: state)
            return
        }

        let tools = self.tools
        let version = self.serverVersion
        Task {
            let (status, json) = await MCPRouter.handle(
                body: request.body, tools: tools, serverVersion: version)
            let reason: String
            switch status {
            case 202: reason = "Accepted"
            case 200: reason = "OK"
            default: reason = "OK"
            }
            let body = json ?? Data()
            let contentType = json == nil ? nil : "application/json"
            let response = MCPHTTP.response(
                status: status, reason: reason, contentType: contentType, body: body)
            self.reply(response, on: conn, state: state)
        }
    }

    private func reply(_ data: Data, on conn: NWConnection, state: MCPConnectionState) {
        conn.send(content: data, completion: .contentProcessed { _ in
            state.finish()
            conn.cancel()
        })
    }
}

private final class MCPConnectionState: @unchecked Sendable {
    private let onFinish: () -> Void
    private let lock = NSLock()
    private var finished = false
    private var readDeadline: DispatchWorkItem?

    init(onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func installReadDeadline(_ workItem: DispatchWorkItem) {
        lock.lock()
        readDeadline = workItem
        lock.unlock()
    }

    func cancelReadDeadline() {
        lock.lock()
        let workItem = readDeadline
        readDeadline = nil
        lock.unlock()
        workItem?.cancel()
    }

    @discardableResult
    func finish() -> Bool {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return false
        }
        finished = true
        let workItem = readDeadline
        readDeadline = nil
        lock.unlock()
        workItem?.cancel()
        onFinish()
        return true
    }
}

enum MCPServerError: Error, LocalizedError {
    case bindFailed

    var errorDescription: String? {
        switch self {
        case .bindFailed:
            return "Could not bind the MCP server to 127.0.0.1 (is the port already in use?)"
        }
    }
}

/// Tiny lock-guarded bool for the bind-failure handshake between the
/// listener queue and the starting thread.
private final class MCPAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}
