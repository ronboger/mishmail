import Foundation
import Network

/// In-process MCP Streamable HTTP server (JSON-RPC over HTTP/1.1).
///
/// Binds 127.0.0.1 only on an ephemeral port. Single endpoint `POST /mcp`
/// with Bearer auth. Modeled on `OAuthService.startLoopbackListener`.
final class MCPServer: @unchecked Sendable {
    /// Max request size (headers + body). Over this → close without reply.
    static let maxRequestBytes = 2 * 1024 * 1024

    private let tools: any MCPToolProvider
    private let serverVersion: String
    private var listener: NWListener?
    private var token: String = ""
    private let queue = DispatchQueue(label: "dev.ronboger.MishMail.mcp", qos: .userInitiated)
    private let lock = NSLock()

    init(tools: any MCPToolProvider, serverVersion: String = MCPRouter.defaultServerVersion) {
        self.tools = tools
        self.serverVersion = serverVersion
    }

    /// Start listening. Returns the bound port.
    @discardableResult
    func start(token: String) throws -> UInt16 {
        lock.lock()
        defer { lock.unlock() }
        if listener != nil { stopUnlocked() }

        self.token = token
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }
        listener.stateUpdateHandler = { state in
            if case .failed = state {
                // Listener failed (e.g. interface down); caller can restart.
            }
        }
        listener.start(queue: queue)
        self.listener = listener

        var port: UInt16 = 0
        for _ in 0..<100 {
            if let p = listener.port?.rawValue, p != 0 {
                port = p
                break
            }
            usleep(10_000)
        }
        guard port != 0 else {
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

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: queue)
        accumulate(on: conn, into: Data())
    }

    private func accumulate(on conn: NWConnection, into buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: Self.maxRequestBytes) {
            [weak self] data, _, isComplete, error in
            guard let self else {
                conn.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }

            if buffer.count > Self.maxRequestBytes {
                conn.cancel()
                return
            }

            if let request = MCPHTTP.parse(buffer) {
                self.serve(request, on: conn)
                return
            }

            if error != nil || isComplete {
                conn.cancel()
                return
            }
            self.accumulate(on: conn, into: buffer)
        }
    }

    private func serve(_ request: MCPHTTPRequest, on conn: NWConnection) {
        // Path / method gates before auth so probes don't need the token shape.
        guard request.path == "/mcp" else {
            reply(MCPHTTP.response(status: 404, reason: "Not Found"), on: conn)
            return
        }
        guard request.method.uppercased() == "POST" else {
            // GET /mcp and any other method → 405.
            reply(MCPHTTP.response(status: 405, reason: "Method Not Allowed"), on: conn)
            return
        }

        let expected = token
        guard let presented = MCPHTTP.bearerToken(from: request.headers),
              presented == expected, !expected.isEmpty else {
            reply(MCPHTTP.response(status: 401, reason: "Unauthorized"), on: conn)
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
            self.reply(response, on: conn)
        }
    }

    private func reply(_ data: Data, on conn: NWConnection) {
        conn.send(content: data, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}

enum MCPServerError: Error, LocalizedError {
    case bindFailed

    var errorDescription: String? {
        switch self {
        case .bindFailed: return "Could not bind the MCP server to 127.0.0.1"
        }
    }
}
