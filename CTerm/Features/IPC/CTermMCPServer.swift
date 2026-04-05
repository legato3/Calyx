//
//  CTermMCPServer.swift
//  CTerm
//
//  MCP server: accepts JSON-RPC over TCP, authenticates via bearer token,
//  routes to MCPRouter / IPCStore for IPC tool calls.
//

import AppKit
import Foundation
import Network

@MainActor
final class CTermMCPServer {

    static let shared = CTermMCPServer()

    // MARK: - Public State

    private(set) var isRunning: Bool = false
    private(set) var port: Int = 0
    private(set) var token: String = ""
    let store = IPCStore()
    private(set) var appPeerID: UUID?
    private var peerRegistrationTask: Task<Void, Never>?

    // MARK: - Private

    private var listener: NWListener?

    private static let iso8601: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt
    }()

    // MARK: - Init

    init() {}

    /// Initializer for testing: creates a server with a pre-set token so tests can
    /// exercise handleJSONRPC without going through start() / NWListener.
    init(testToken: String) {
        self.token = testToken
    }

    // MARK: - Lifecycle

    func start(token: String, preferredPort: Int = 41830) throws {
        if isRunning { stop() }

        self.token = token

        var lastError: Error?

        for portOffset in 0..<10 {
            let tryPort = preferredPort + portOffset
            do {
                let params = NWParameters.tcp
                let nwPort = NWEndpoint.Port(integerLiteral: UInt16(tryPort))
                params.requiredLocalEndpoint = NWEndpoint.hostPort(
                    host: .ipv4(.loopback),
                    port: nwPort
                )
                let nl = try NWListener(using: params)

                nl.newConnectionHandler = { [weak self] connection in
                    Task { @MainActor in
                        self?.handleConnection(connection)
                    }
                }
                // Set isRunning only after the listener confirms it's bound and accepting.
                nl.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            self.isRunning = true
                        case .failed, .cancelled:
                            self.isRunning = false
                        default:
                            break
                        }
                    }
                }
                nl.start(queue: .main)

                self.listener = nl
                self.port = tryPort
                self.peerRegistrationTask = Task {
                    let peer = await self.store.registerPeer(name: "cterm-app", role: "review-ui")
                    self.appPeerID = peer.id
                }
                return
            } catch {
                lastError = error
                continue
            }
        }

        throw lastError ?? NSError(
            domain: "CTermMCPServer",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Failed to bind to any port in range \(preferredPort)-\(preferredPort + 9)",
            ]
        )
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        appPeerID = nil
        peerRegistrationTask?.cancel()
        peerRegistrationTask = nil
        port = 0
        Task { await store.cleanup() }
    }

    /// Ensures the app peer is registered before proceeding.
    /// Call this before accessing `appPeerID` from async contexts.
    func ensureAppPeerRegistered() async {
        await peerRegistrationTask?.value
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: HTTPParser.maxHeaderSize + HTTPParser.maxBodySize) { [weak self] data, _, _, error in
            Task { @MainActor [weak self] in
                guard let self, let data else {
                    connection.cancel()
                    return
                }

                do {
                    let httpRequest = try HTTPParser.parse(data)

                    // Only accept POST /mcp
                    guard httpRequest.method == "POST", httpRequest.path == "/mcp" else {
                        self.sendHTTPResponse(connection: connection, httpResponse: HTTPParser.response(statusCode: 404, body: nil))
                        return
                    }

                    // Extract bearer token from Authorization header (case-insensitive)
                    let authToken: String? = {
                        for (key, value) in httpRequest.headers {
                            if key.lowercased() == "authorization", value.hasPrefix("Bearer ") {
                                return String(value.dropFirst(7))
                            }
                        }
                        return nil
                    }()

                    guard let body = httpRequest.body else {
                        self.sendHTTPResponse(connection: connection, httpResponse: HTTPParser.response(statusCode: 400, body: nil))
                        return
                    }

                    let (statusCode, responseBody) = await self.handleJSONRPC(data: body, authToken: authToken)
                    let httpResponse = HTTPParser.response(statusCode: statusCode, body: responseBody)
                    self.sendHTTPResponse(connection: connection, httpResponse: httpResponse)
                } catch let error as HTTPParseError {
                    let statusCode: Int
                    switch error {
                    case .headerTooLarge, .bodyTooLarge: statusCode = 413
                    case .invalidContentLength, .malformedRequest: statusCode = 400
                    case .timeout: statusCode = 408
                    }
                    self.sendHTTPResponse(connection: connection, httpResponse: HTTPParser.response(statusCode: statusCode, body: nil))
                } catch {
                    self.sendHTTPResponse(connection: connection, httpResponse: HTTPParser.response(statusCode: 500, body: nil))
                }
            }
        }
    }

    private func sendHTTPResponse(connection: NWConnection, httpResponse: HTTPResponse) {
        let data = httpResponse.serialize()
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - JSON-RPC Handler

    /// Process a single JSON-RPC request.
    /// Returns an HTTP-like status code and optional response body.
    func handleJSONRPC(data: Data, authToken: String?) async -> (statusCode: Int, body: Data?) {

        // 1. Authentication
        guard let authToken, authToken == token else {
            return unauthorizedResponse()
        }

        // 2. Parse JSON
        let request: JSONRPCRequest
        do {
            request = try JSONDecoder().decode(JSONRPCRequest.self, from: data)
        } catch {
            let resp = MCPRouter.buildErrorResponse(id: nil, code: -32700, message: "Parse error")
            return (200, encode(resp))
        }

        // 3. Notifications (no id) → 204
        guard let requestId = request.id else {
            return (204, nil)
        }

        // 4. Route by method
        switch request.method {
        case "initialize":
            // Do NOT auto-register here — all Claude Code clients send clientInfo.name="claude-code"
            // which causes every agent to collide on the same peer UUID and share one inbox.
            // Agents must call register_peer explicitly to get a unique peer_id.
            let resp = MCPRouter.buildInitializeResponse(id: requestId, peerID: nil)
            return (200, encode(resp))

        case "tools/list":
            let resp = MCPRouter.buildToolsListResponse(id: requestId)
            return (200, encode(resp))

        case "notifications/initialized":
            return (204, nil)

        case "tools/call":
            return await handleToolCall(id: requestId, params: request.params)

        default:
            let resp = MCPRouter.buildErrorResponse(id: requestId, code: -32601, message: "Method not found")
            return (200, encode(resp))
        }
    }

    // MARK: - Tool Call Dispatch

    private func handleToolCall(
        id: JSONRPCId,
        params: [String: AnyCodable]?
    ) async -> (statusCode: Int, body: Data?) {

        guard let params else {
            return toolError(id: id, text: "Missing params")
        }

        guard let toolName = extractString(params, "name") else {
            return toolError(id: id, text: "Missing tool name")
        }

        let arguments = extractDict(params, "arguments")

        switch toolName {
        case "register_peer":
            return await handleRegisterPeer(id: id, arguments: arguments)

        case "list_peers":
            return await handleListPeers(id: id)

        case "send_message":
            return await handleSendMessage(id: id, arguments: arguments)

        case "broadcast":
            return await handleBroadcast(id: id, arguments: arguments)

        case "receive_messages":
            return await handleReceiveMessages(id: id, arguments: arguments)

        case "ack_messages":
            return await handleAckMessages(id: id, arguments: arguments)

        case "get_peer_status":
            return await handleGetPeerStatus(id: id, arguments: arguments)

        case "heartbeat":
            return await handleHeartbeat(id: id, arguments: arguments)

        case "show_quick_terminal":
            return handleShowQuickTerminal(id: id)

        case "get_workspace_state":
            return handleGetWorkspaceState(id: id)

        case "create_tab":
            return handleCreateTab(id: id, arguments: arguments)

        case "create_split":
            return handleCreateSplit(id: id, arguments: arguments)

        case "run_in_pane":
            return handleRunInPane(id: id, arguments: arguments)

        case "focus_pane":
            return handleFocusPane(id: id, arguments: arguments)

        case "set_tab_title":
            return handleSetTabTitle(id: id, arguments: arguments)

        case "show_notification":
            return handleShowNotification(id: id, arguments: arguments)

        case "get_git_status":
            return await handleGetGitStatus(id: id)

        case "get_pane_output":
            return handleGetPaneOutput(id: id, arguments: arguments)

        case "report_file_change":
            return await handleReportFileChange(id: id, arguments: arguments)

        case "delegate_task":
            return await handleDelegateTask(id: id, arguments: arguments)

        case "report_result":
            return await handleReportResult(id: id, arguments: arguments)

        case "get_delegations":
            return await handleGetDelegations(id: id, arguments: arguments)

        case "get_aggregated_result":
            return await handleGetAggregatedResult(id: id, arguments: arguments)

        case "queue_task":
            return handleQueueTask(id: id, arguments: arguments)

        case "get_queue":
            return handleGetQueue(id: id)

        case "complete_task":
            return handleCompleteTask(id: id, arguments: arguments)

        case "clear_queue":
            return handleClearQueue(id: id)

        case "get_last_error":
            return handleGetLastError(id: id, arguments: arguments)

        case "remember":
            return handleRemember(id: id, arguments: arguments)

        case "recall":
            return handleRecall(id: id, arguments: arguments)

        case "forget":
            return handleForget(id: id, arguments: arguments)

        case "list_memories":
            return handleListMemories(id: id, arguments: arguments)

        case "compact_memories":
            return handleCompactMemories(id: id, arguments: arguments)

        case "get_project_context":
            return handleGetProjectContext(id: id, arguments: arguments)

        case "get_session_summary":
            return handleGetSessionSummary(id: id)

        case "get_test_results":
            return handleGetTestResults(id: id)

        case "run_tests":
            return handleRunTests(id: id, arguments: arguments)

        case "search_terminal_output":
            return handleSearchTerminalOutput(id: id, arguments: arguments)

        case "wait_for_pane_idle":
            return await handleWaitForPaneIdle(id: id, arguments: arguments)

        case "get_last_handoff":
            return handleGetLastHandoff(id: id, arguments: arguments)

        case "get_agent_environment":
            return handleGetAgentEnvironment(id: id, arguments: arguments)

        default:
            return toolError(id: id, text: "Unknown tool: \(toolName)")
        }
    }

    // MARK: - Tool Handlers

    private func handleRegisterPeer(
        id: JSONRPCId,
        arguments: [String: AnyCodable]?
    ) async -> (statusCode: Int, body: Data?) {
        let name = arguments?["name"]?.stringValue ?? ""
        let role = arguments?["role"]?.stringValue ?? ""
        let peer = await store.registerPeer(name: name, role: role)

        // Auto-checkpoint the active tab's repo before Claude starts editing.
        let pwd = await TerminalControlBridge.shared.delegate?.activeTabPwd
        await CheckpointManager.shared.maybeAutoCheckpoint(workDir: pwd)

        // Notify trigger engine of peer connection.
        NotificationCenter.default.post(
            name: .peerRegistered,
            object: nil,
            userInfo: ["name": peer.name, "role": peer.role]
        )

        // Build response — include project context when auto-inject is enabled (default: on).
        let autoInject = UserDefaults.standard.object(forKey: "CTermAutoInjectContext") as? Bool ?? true
        var result: [String: Any] = ["peerId": peer.id.uuidString]

        if autoInject, let workDir = pwd {
            let ctx = ProjectContextProvider.gather(workDir: workDir)
            result["project_context"] = ctx
            result["context_hint"] = "Project context is included above. Use it to orient yourself without asking the user to re-explain the project."
        }

        guard let data = try? JSONSerialization.data(withJSONObject: result),
              let json = String(data: data, encoding: .utf8) else {
            return toolSuccess(id: id, text: "{\"peerId\":\"\(peer.id.uuidString)\"}")
        }
        return toolSuccess(id: id, text: json)
    }

    private func handleListPeers(
        id: JSONRPCId
    ) async -> (statusCode: Int, body: Data?) {
        let peers = await store.listPeers()
        let peerDicts: [[String: Any]] = peers.map { peerToDict($0) }
        let result: [String: Any] = ["peers": peerDicts]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: result),
              let json = String(data: jsonData, encoding: .utf8) else {
            return toolError(id: id, text: "Failed to serialize peers")
        }
        return toolSuccess(id: id, text: json)
    }

    private func handleSendMessage(
        id: JSONRPCId,
        arguments: [String: AnyCodable]?
    ) async -> (statusCode: Int, body: Data?) {
        guard let fromStr = arguments?["from"]?.stringValue,
              let toStr = arguments?["to"]?.stringValue,
              let content = arguments?["content"]?.stringValue,
              let fromUUID = UUID(uuidString: fromStr) else {
            return toolError(id: id, text: "Missing or invalid from/to/content")
        }

        // Resolve 'to' as UUID or peer name
        let toUUID: UUID
        if let uuid = UUID(uuidString: toStr) {
            toUUID = uuid
        } else if let peer = await store.peer(named: toStr) {
            toUUID = peer.id
        } else {
            return toolError(id: id, text: "Peer not found: \"\(toStr)\". Use list_peers to see available peers.")
        }

        let topic = arguments?["topic"]?.stringValue
        let replyTo = arguments?["reply_to"]?.stringValue

        do {
            let message = try await store.sendMessage(from: fromUUID, to: toUUID, content: content, topic: topic, replyTo: replyTo)
            let json = "{\"messageId\":\"\(message.id.uuidString)\"}"
            return toolSuccess(id: id, text: json)
        } catch let error as IPCError {
            return toolError(id: id, text: error.errorDescription ?? error.localizedDescription)
        } catch {
            return toolError(id: id, text: error.localizedDescription)
        }
    }

    private func handleBroadcast(
        id: JSONRPCId,
        arguments: [String: AnyCodable]?
    ) async -> (statusCode: Int, body: Data?) {
        guard let fromStr = arguments?["from"]?.stringValue,
              let content = arguments?["content"]?.stringValue,
              let fromUUID = UUID(uuidString: fromStr) else {
            return toolError(id: id, text: "Missing or invalid from/content")
        }

        let topic = arguments?["topic"]?.stringValue

        do {
            let messages = try await store.broadcast(from: fromUUID, content: content, topic: topic)
            let json = "{\"messageCount\":\(messages.count)}"
            return toolSuccess(id: id, text: json)
        } catch let error as IPCError {
            return toolError(id: id, text: error.errorDescription ?? error.localizedDescription)
        } catch {
            return toolError(id: id, text: error.localizedDescription)
        }
    }

    private func handleReceiveMessages(
        id: JSONRPCId,
        arguments: [String: AnyCodable]?
    ) async -> (statusCode: Int, body: Data?) {
        guard let peerStr = arguments?["peer_id"]?.stringValue,
              let peerUUID = UUID(uuidString: peerStr) else {
            return toolError(id: id, text: "Missing or invalid peer_id")
        }

        // Parse optional 'since' cursor
        let since: Date? = arguments?["since"]?.stringValue.flatMap { Self.iso8601.date(from: $0) }
        let topic = arguments?["topic"]?.stringValue

        let messages = await store.receiveMessages(for: peerUUID, since: since, topic: topic)

        // Resolve sender names for all messages in one pass
        let peers = await store.listPeers()
        let peerNames: [UUID: String] = Dictionary(uniqueKeysWithValues: peers.map { ($0.id, $0.name) })

        let messageDicts: [[String: Any]] = messages.map { messageToDict($0, fromName: peerNames[$0.from]) }
        let result: [String: Any] = ["messages": messageDicts]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: result),
              let json = String(data: jsonData, encoding: .utf8) else {
            return toolError(id: id, text: "Failed to serialize messages")
        }
        return toolSuccess(id: id, text: json)
    }

    private func handleAckMessages(
        id: JSONRPCId,
        arguments: [String: AnyCodable]?
    ) async -> (statusCode: Int, body: Data?) {
        guard let peerStr = arguments?["peer_id"]?.stringValue,
              let peerUUID = UUID(uuidString: peerStr) else {
            return toolError(id: id, text: "Missing or invalid peer_id/message_ids")
        }
        let messageIdStrings = (arguments?["message_ids"]?.rawValue as? [Any])?.compactMap { $0 as? String } ?? []

        let messageUUIDs = messageIdStrings.compactMap { UUID(uuidString: $0) }
        await store.ackMessages(ids: messageUUIDs, for: peerUUID)
        let json = "{\"acknowledged\":\(messageUUIDs.count)}"
        return toolSuccess(id: id, text: json)
    }

    private func handleGetPeerStatus(
        id: JSONRPCId,
        arguments: [String: AnyCodable]?
    ) async -> (statusCode: Int, body: Data?) {
        guard let peerStr = arguments?["peer_id"]?.stringValue,
              let peerUUID = UUID(uuidString: peerStr) else {
            return toolError(id: id, text: "Missing or invalid peer_id")
        }

        guard let peer = await store.peerStatus(id: peerUUID) else {
            return toolError(id: id, text: "Peer not found")
        }

        let dict = peerToDict(peer)
        guard let jsonData = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: jsonData, encoding: .utf8) else {
            return toolError(id: id, text: "Failed to serialize peer")
        }
        return toolSuccess(id: id, text: json)
    }

    private func handleHeartbeat(
        id: JSONRPCId,
        arguments: [String: AnyCodable]?
    ) async -> (statusCode: Int, body: Data?) {
        guard let peerStr = arguments?["peer_id"]?.stringValue,
              let peerUUID = UUID(uuidString: peerStr) else {
            return toolError(id: id, text: "Missing or invalid peer_id")
        }

        let alive = await store.heartbeat(for: peerUUID)
        guard alive else {
            return toolError(id: id, text: "Peer not found or expired: \(peerUUID). Call register_peer to re-register.")
        }
        let json = "{\"status\":\"ok\"}"
        return toolSuccess(id: id, text: json)
    }

    private func handleShowQuickTerminal(id: JSONRPCId) -> (statusCode: Int, body: Data?) {
        (NSApp.delegate as? AppDelegate)?.toggleQuickTerminal()
        return toolSuccess(id: id, text: "{\"toggled\":true}")
    }

    // MARK: - Terminal Control Tool Handlers

    private func handleGetWorkspaceState(id: JSONRPCId) -> (statusCode: Int, body: Data?) {
        guard let delegate = TerminalControlBridge.shared.delegate else {
            return toolError(id: id, text: "No active window")
        }
        let state = delegate.getWorkspaceState()
        guard let json = try? JSONEncoder().encode(state),
              let text = String(data: json, encoding: .utf8) else {
            return toolError(id: id, text: "Failed to encode workspace state")
        }
        return toolSuccess(id: id, text: text)
    }

    private func handleCreateTab(
        id: JSONRPCId,
        arguments: [String: AnyCodable]?
    ) -> (statusCode: Int, body: Data?) {
        guard let delegate = TerminalControlBridge.shared.delegate else {
            return toolError(id: id, text: "No active window")
        }
        let pwd = arguments?["pwd"]?.stringValue
        let title = arguments?["title"]?.stringValue
        let command = arguments?["command"]?.stringValue
        delegate.createTab(pwd: pwd, title: title, command: command)
        return toolSuccess(id: id, text: "{\"created\":true}")
    }

    private func handleCreateSplit(
        id: JSONRPCId,
        arguments: [String: AnyCodable]?
    ) -> (statusCode: Int, body: Data?) {
        guard let delegate = TerminalControlBridge.shared.delegate else {
            return toolError(id: id, text: "No active window")
        }
        let direction = arguments?["direction"]?.stringValue ?? "vertical"
        delegate.createSplit(direction: direction)
        return toolSuccess(id: id, text: "{\"created\":true}")
    }

    private func handleRunInPane(
        id: JSONRPCId,
        arguments: [String: AnyCodable]?
    ) -> (statusCode: Int, body: Data?) {
        guard let delegate = TerminalControlBridge.shared.delegate else {
            return toolError(id: id, text: "No active window")
        }
        guard let text = arguments?["text"]?.stringValue else {
            return toolError(id: id, text: "Missing required argument: text")
        }
        let tabID = arguments?["tab_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        let paneID = arguments?["pane_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        let pressEnter = arguments?["press_enter"]?.boolValue ?? false
        let sent = delegate.runInPane(tabID: tabID, paneID: paneID, text: text, pressEnter: pressEnter)
        if sent {
            return toolSuccess(id: id, text: "{\"sent\":true}")
        } else {
            return toolError(id: id, text: "Pane not found. Use get_workspace_state to list pane IDs.")
        }
    }

    private func handleFocusPane(
        id: JSONRPCId,
        arguments: [String: AnyCodable]?
    ) -> (statusCode: Int, body: Data?) {
        guard let delegate = TerminalControlBridge.shared.delegate else {
            return toolError(id: id, text: "No active window")
        }
        guard let paneIDStr = arguments?["pane_id"]?.stringValue,
              let paneID = UUID(uuidString: paneIDStr) else {
            return toolError(id: id, text: "Missing or invalid pane_id")
        }
        let found = delegate.focusPane(paneID: paneID)
        if found {
            return toolSuccess(id: id, text: "{\"focused\":true}")
        } else {
            return toolError(id: id, text: "Pane not found: \(paneIDStr)")
        }
    }

    private func handleSetTabTitle(
        id: JSONRPCId,
        arguments: [String: AnyCodable]?
    ) -> (statusCode: Int, body: Data?) {
        guard let delegate = TerminalControlBridge.shared.delegate else {
            return toolError(id: id, text: "No active window")
        }
        guard let tabIDStr = arguments?["tab_id"]?.stringValue,
              let tabID = UUID(uuidString: tabIDStr),
              let title = arguments?["title"]?.stringValue else {
            return toolError(id: id, text: "Missing or invalid tab_id or title")
        }
        let found = delegate.setTabTitle(tabID: tabID, title: title)
        if found {
            return toolSuccess(id: id, text: "{\"updated\":true}")
        } else {
            return toolError(id: id, text: "Tab not found: \(tabIDStr)")
        }
    }

    private func handleShowNotification(
        id: JSONRPCId,
        arguments: [String: AnyCodable]?
    ) -> (statusCode: Int, body: Data?) {
        guard let title = arguments?["title"]?.stringValue,
              let body = arguments?["body"]?.stringValue else {
            return toolError(id: id, text: "Missing required arguments: title and body")
        }
        let delegate = TerminalControlBridge.shared.delegate
        if let delegate {
            delegate.showNotification(title: title, body: body)
        } else {
            // Fallback: send directly even without a window delegate
            NotificationManager.shared.sendNotification(title: title, body: body, tabID: UUID())
        }
        return toolSuccess(id: id, text: "{\"sent\":true}")
    }

    private func handleGetGitStatus(id: JSONRPCId) async -> (statusCode: Int, body: Data?) {
        guard let delegate = TerminalControlBridge.shared.delegate else {
            return toolError(id: id, text: "No active window")
        }
        let status = await delegate.getGitStatus()
        let escaped = status.replacingOccurrences(of: "\\", with: "\\\\")
                            .replacingOccurrences(of: "\"", with: "\\\"")
                            .replacingOccurrences(of: "\n", with: "\\n")
        return toolSuccess(id: id, text: "{\"status\":\"\(escaped)\"}")
    }

    private func handleGetPaneOutput(
        id: JSONRPCId,
        arguments: [String: AnyCodable]?
    ) -> (statusCode: Int, body: Data?) {
        guard let delegate = TerminalControlBridge.shared.delegate else {
            return toolError(id: id, text: "No active window")
        }
        let tabID = arguments?["tab_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        let paneID = arguments?["pane_id"]?.stringValue.flatMap(UUID.init(uuidString:))
        let output = delegate.getPaneOutput(tabID: tabID, paneID: paneID) ?? ""
        let escaped = output.replacingOccurrences(of: "\\", with: "\\\\")
                            .replacingOccurrences(of: "\"", with: "\\\"")
                            .replacingOccurrences(of: "\n", with: "\\n")
        return toolSuccess(id: id, text: "{\"output\":\"\(escaped)\"}")
    }

    private func handleReportFileChange(
        id: JSONRPCId,
        arguments: [String: AnyCodable]?
    ) async -> (statusCode: Int, body: Data?) {
        guard let peerIDStr = arguments?["peer_id"]?.stringValue,
              let peerID = UUID(uuidString: peerIDStr) else {
            return toolError(id: id, text: "Missing or invalid peer_id")
        }
        guard let path = arguments?["path"]?.stringValue, !path.isEmpty else {
            return toolError(id: id, text: "Missing path")
        }
        let workDir = arguments?["work_dir"]?.stringValue
            ?? TerminalControlBridge.shared.delegate?.activeTabPwd
            ?? NSHomeDirectory()

        // look up peer name
        let peer = await store.getPeer(id: peerID)
        let peerName = peer?.name ?? "unknown"

        FileChangeStore.shared.report(path: path, workDir: workDir, peerID: peerID, peerName: peerName)
        let escapedPath = path.replacingOccurrences(of: "\\", with: "\\\\")
                             .replacingOccurrences(of: "\"", with: "\\\"")
        return toolSuccess(id: id, text: "{\"recorded\":true,\"path\":\"\(escapedPath)\"}")
    }

    // MARK: - Task Queue Handlers

    private func handleQueueTask(
        id: JSONRPCId,
        arguments: [String: AnyCodable]?
    ) -> (statusCode: Int, body: Data?) {
        guard let prompt = arguments?["prompt"]?.stringValue, !prompt.isEmpty else {
            return toolError(id: id, text: "Missing prompt")
        }
        let targetPeer = arguments?["target_peer"]?.stringValue
        let position = arguments?["position"]?.rawValue as? Int
        // CTermMCPServer is @MainActor — call directly so pendingCount reflects the enqueue.
        TaskQueueStore.shared.enqueue(prompt, targetPeerName: targetPeer, at: position)
        return toolSuccess(id: id, text: "{\"queued\":true,\"pending\":\(TaskQueueStore.shared.pendingCount)}")
    }

    private func handleGetQueue(id: JSONRPCId) -> (statusCode: Int, body: Data?) {
        let tasks = TaskQueueStore.shared.tasks
        let items = tasks.map { t -> [String: Any] in
            var d: [String: Any] = [
                "id": t.id.uuidString,
                "prompt": String(t.prompt.prefix(200)),
                "status": t.status.rawValue,
            ]
            if let target = t.targetPeerName { d["target_peer"] = target }
            if let snippet = t.resultSnippet { d["result_snippet"] = String(snippet.prefix(100)) }
            return d
        }
        let json = (try? JSONSerialization.data(withJSONObject: ["tasks": items])).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? "{\"tasks\":[]}"
        return toolSuccess(id: id, text: json)
    }

    private func handleCompleteTask(
        id: JSONRPCId,
        arguments: [String: AnyCodable]?
    ) -> (statusCode: Int, body: Data?) {
        let result = arguments?["result"]?.stringValue
        TaskQueueStore.shared.completeCurrent(result: result)
        return toolSuccess(id: id, text: "{\"advanced\":true}")
    }

    private func handleClearQueue(id: JSONRPCId) -> (statusCode: Int, body: Data?) {
        TaskQueueStore.shared.clearPending()
        return toolSuccess(id: id, text: "{\"cleared\":true}")
    }

    // MARK: - Delegation Handlers

    private func handleDelegateTask(
        id: JSONRPCId,
        arguments: [String: AnyCodable]?
    ) async -> (statusCode: Int, body: Data?) {
        guard let fromStr = arguments?["from"]?.stringValue,
              let fromUUID = UUID(uuidString: fromStr) else {
            return toolError(id: id, text: "Missing or invalid 'from' peer ID")
        }
        guard let targetPeer = arguments?["target_peer"]?.stringValue, !targetPeer.isEmpty else {
            return toolError(id: id, text: "Missing 'target_peer'")
        }
        guard let prompt = arguments?["prompt"]?.stringValue, !prompt.isEmpty else {
            return toolError(id: id, text: "Missing 'prompt'")
        }

        let formatStr = arguments?["expected_format"]?.stringValue ?? "freeText"
        let expectedFormat = ExpectedOutputFormat(rawValue: formatStr) ?? .freeText
        let timeout = (arguments?["timeout"]?.rawValue as? Double) ?? 300
        let maxRetries = (arguments?["max_retries"]?.rawValue as? Int) ?? 1
        let groupID = arguments?["group_id"]?.stringValue.flatMap { UUID(uuidString: $0) }

        let contract = await DelegationCoordinator.shared.createContract(
            ownerPeerID: fromUUID,
            targetPeerName: targetPeer,
            prompt: prompt,
            expectedFormat: expectedFormat,
            timeoutSeconds: timeout,
            maxRetries: maxRetries,
            groupID: groupID
        )

        let result: [String: Any] = [
            "task_id": contract.id.uuidString,
            "status": contract.status.rawValue,
            "target_peer": contract.targetPeerName,
            "timeout_seconds": Int(timeout),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: result),
              let json = String(data: data, encoding: .utf8) else {
            return toolSuccess(id: id, text: "{\"task_id\":\"\(contract.id.uuidString)\"}")
        }
        return toolSuccess(id: id, text: json)
    }

    private func handleReportResult(
        id: JSONRPCId,
        arguments: [String: AnyCodable]?
    ) async -> (statusCode: Int, body: Data?) {
        guard let taskIDStr = arguments?["task_id"]?.stringValue,
              let taskID = UUID(uuidString: taskIDStr) else {
            return toolError(id: id, text: "Missing or invalid 'task_id'")
        }
        guard let peerName = arguments?["peer_name"]?.stringValue else {
            return toolError(id: id, text: "Missing 'peer_name'")
        }
        guard let content = arguments?["content"]?.stringValue else {
            return toolError(id: id, text: "Missing 'content'")
        }

        let (accepted, error) = await DelegationCoordinator.shared.reportResult(
            taskID: taskID,
            peerName: peerName,
            content: content
        )

        if accepted {
            return toolSuccess(id: id, text: "{\"accepted\":true}")
        } else {
            return toolError(id: id, text: error ?? "Result not accepted")
        }
    }

    private func handleGetDelegations(
        id: JSONRPCId,
        arguments: [String: AnyCodable]?
    ) async -> (statusCode: Int, body: Data?) {
        let contracts: [DelegationContract]

        if let ownerStr = arguments?["owner_peer_id"]?.stringValue,
           let ownerID = UUID(uuidString: ownerStr) {
            contracts = await DelegationCoordinator.shared.contractsForOwner(ownerID)
        } else if let targetPeer = arguments?["target_peer"]?.stringValue {
            contracts = await DelegationCoordinator.shared.contractsForTarget(targetPeer)
        } else if let groupStr = arguments?["group_id"]?.stringValue,
                  let groupID = UUID(uuidString: groupStr) {
            let agg = await DelegationCoordinator.shared.aggregatedResult(groupID: groupID)
            contracts = agg.contracts
        } else {
            contracts = await DelegationCoordinator.shared.allContracts()
        }

        let items: [[String: Any]] = contracts.map { c in
            var d: [String: Any] = [
                "task_id": c.id.uuidString,
                "target_peer": c.targetPeerName,
                "status": c.status.rawValue,
                "prompt": String(c.prompt.prefix(200)),
                "elapsed_seconds": Int(c.elapsedSeconds),
                "expected_format": c.expectedFormat.rawValue,
            ]
            if let error = c.lastError { d["error"] = error }
            if let result = c.result { d["has_result"] = true; d["result_valid"] = result.isValid }
            if let groupID = c.groupID { d["group_id"] = groupID.uuidString }
            return d
        }

        let json = (try? JSONSerialization.data(withJSONObject: ["delegations": items])).flatMap {
            String(data: $0, encoding: .utf8)
        } ?? "{\"delegations\":[]}"
        return toolSuccess(id: id, text: json)
    }

    private func handleGetAggregatedResult(
        id: JSONRPCId,
        arguments: [String: AnyCodable]?
    ) async -> (statusCode: Int, body: Data?) {
        guard let groupStr = arguments?["group_id"]?.stringValue,
              let groupID = UUID(uuidString: groupStr) else {
            return toolError(id: id, text: "Missing or invalid 'group_id'")
        }

        let agg = await DelegationCoordinator.shared.aggregatedResult(groupID: groupID)

        let result: [String: Any] = [
            "group_id": groupID.uuidString,
            "total": agg.contracts.count,
            "completed": agg.completedResults.count,
            "failed": agg.failedContracts.count,
            "is_complete": agg.isComplete,
            "summary": agg.summary,
            "combined_output": String(agg.combinedOutput.prefix(8000)),
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: result),
              let json = String(data: data, encoding: .utf8) else {
            return toolError(id: id, text: "Failed to serialize aggregated result")
        }
        return toolSuccess(id: id, text: json)
    }

    private func handleGetLastError(id: JSONRPCId, arguments: [String: AnyCodable]?) -> (statusCode: Int, body: Data?) {
        let filterTabID = arguments?["tab_id"]?.stringValue.flatMap { UUID(uuidString: $0) }

        let result: [String: Any]
        if let event = findLastError(tabID: filterTabID) {
            result = [
                "found": true,
                "tab_id": event.tabID.uuidString,
                "tab_title": event.tabTitle,
                "snippet": event.snippet,
                "timestamp": Self.iso8601.string(from: event.timestamp),
            ]
        } else {
            result = ["found": false]
        }

        guard let data = try? JSONSerialization.data(withJSONObject: result),
              let text = String(data: data, encoding: .utf8) else {
            return toolSuccess(id: id, text: "{\"found\":false}")
        }
        return toolSuccess(id: id, text: text)
    }

    // MARK: - Agent Memory

    private func handleRemember(id: JSONRPCId, arguments: [String: AnyCodable]?) -> (statusCode: Int, body: Data?) {
        guard let rawKey = arguments?["key"]?.stringValue, !rawKey.isEmpty,
              let value = arguments?["value"]?.stringValue, !value.isEmpty else {
            return toolError(id: id, text: "remember requires non-empty 'key' and 'value'")
        }
        let ttlDays = arguments?["ttl_days"]?.rawValue as? Int
        let workDir = arguments?["work_dir"]?.stringValue
        let namespace = arguments?["namespace"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let key = namespacedKey(rawKey, namespace: namespace)
        let projectKey = resolvedProjectKey(workDir: workDir)

        // Parse category (defaults to projectFact)
        let category: MemoryCategory = arguments?["category"]?.stringValue
            .flatMap { MemoryCategory(rawValue: $0) } ?? .projectFact
        let importance = (arguments?["importance"]?.rawValue as? Double) ?? category.baseImportance
        let confidence = (arguments?["confidence"]?.rawValue as? Double) ?? 0.8

        let entry = AgentMemoryStore.shared.remember(
            projectKey: projectKey,
            key: key,
            value: value,
            ttlDays: ttlDays ?? category.defaultTTLDays,
            category: category,
            importance: importance,
            confidence: confidence,
            source: .agentExplicit
        )
        NotificationCenter.default.post(name: .agentMemoryChanged, object: nil)

        let result: [String: Any] = [
            "stored": true,
            "key": entry.key,
            "category": entry.category.rawValue,
            "importance": entry.importance,
            "relevance_score": entry.relevanceScore,
            "project_key": projectKey,
            "expires_at": entry.expiresAt.map { Self.iso8601.string(from: $0) } as Any,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: result),
              let text = String(data: data, encoding: .utf8) else {
            return toolSuccess(id: id, text: "{\"stored\":true}")
        }
        return toolSuccess(id: id, text: text)
    }

    private func handleRecall(id: JSONRPCId, arguments: [String: AnyCodable]?) -> (statusCode: Int, body: Data?) {
        let query = arguments?["query"]?.stringValue ?? ""
        let workDir = arguments?["work_dir"]?.stringValue
        let namespace = arguments?["namespace"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let categoryFilter = arguments?["category"]?.stringValue.flatMap { MemoryCategory(rawValue: $0) }
        let projectKey = resolvedProjectKey(workDir: workDir)

        var entries = AgentMemoryStore.shared.recall(
            projectKey: projectKey,
            query: query,
            category: categoryFilter
        )
        // When a namespace is set, only return keys within that namespace prefix.
        if let ns = namespace {
            let prefix = ns + "/"
            entries = entries.filter { $0.key.hasPrefix(prefix) }
        }
        let list = entries.map { e -> [String: Any] in
            var item: [String: Any] = [
                "key": e.key,
                "value": e.value,
                "age": e.age,
                "category": e.category.rawValue,
                "importance": e.importance,
                "relevance_score": e.relevanceScore,
            ]
            if let exp = e.expiresAt { item["expires_at"] = Self.iso8601.string(from: exp) }
            return item
        }
        let result: [String: Any] = ["project_key": projectKey, "count": list.count, "memories": list]
        guard let data = try? JSONSerialization.data(withJSONObject: result),
              let text = String(data: data, encoding: .utf8) else {
            return toolSuccess(id: id, text: "{\"count\":0,\"memories\":[]}")
        }
        return toolSuccess(id: id, text: text)
    }

    private func handleForget(id: JSONRPCId, arguments: [String: AnyCodable]?) -> (statusCode: Int, body: Data?) {
        guard let rawKey = arguments?["key"]?.stringValue, !rawKey.isEmpty else {
            return toolError(id: id, text: "forget requires 'key'")
        }
        let workDir = arguments?["work_dir"]?.stringValue
        let namespace = arguments?["namespace"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let key = namespacedKey(rawKey, namespace: namespace)
        let projectKey = resolvedProjectKey(workDir: workDir)
        let removed = AgentMemoryStore.shared.forget(projectKey: projectKey, key: key)
        if removed { NotificationCenter.default.post(name: .agentMemoryChanged, object: nil) }

        let result: [String: Any] = ["removed": removed, "key": key]
        guard let data = try? JSONSerialization.data(withJSONObject: result),
              let text = String(data: data, encoding: .utf8) else {
            return toolSuccess(id: id, text: "{\"removed\":\(removed)}")
        }
        return toolSuccess(id: id, text: text)
    }

    private func handleListMemories(id: JSONRPCId, arguments: [String: AnyCodable]?) -> (statusCode: Int, body: Data?) {
        let workDir = arguments?["work_dir"]?.stringValue
        let namespace = arguments?["namespace"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let categoryFilter = arguments?["category"]?.stringValue.flatMap { MemoryCategory(rawValue: $0) }
        let projectKey = resolvedProjectKey(workDir: workDir)

        var entries = AgentMemoryStore.shared.listAll(projectKey: projectKey)
        // Filter by namespace
        if let ns = namespace {
            let prefix = ns + "/"
            entries = entries.filter { $0.key.hasPrefix(prefix) }
        }
        // Filter by category
        if let cat = categoryFilter {
            entries = entries.filter { $0.category == cat }
        }
        let list = entries.map { e -> [String: Any] in
            var item: [String: Any] = [
                "key": e.key,
                "value": e.value,
                "age": e.age,
                "category": e.category.rawValue,
                "importance": e.importance,
                "confidence": e.confidence,
                "relevance_score": e.relevanceScore,
                "access_count": e.accessCount,
                "source": e.source.rawValue,
                "updated_at": Self.iso8601.string(from: e.updatedAt),
            ]
            if let exp = e.expiresAt { item["expires_at"] = Self.iso8601.string(from: exp) }
            return item
        }

        // Include stats
        let stats = AgentMemoryStore.shared.stats(projectKey: projectKey)
        let statDict: [String: Any] = [
            "total": stats.totalCount,
            "avg_relevance_score": stats.averageRelevanceScore,
            "by_category": Dictionary(uniqueKeysWithValues: stats.byCategory.map { ($0.key.rawValue, $0.value) }),
        ]

        let result: [String: Any] = [
            "project_key": projectKey,
            "count": list.count,
            "memories": list,
            "stats": statDict,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: result),
              let text = String(data: data, encoding: .utf8) else {
            return toolSuccess(id: id, text: "{\"count\":0,\"memories\":[]}")
        }
        return toolSuccess(id: id, text: text)
    }

    /// Derives the project key from a work_dir string (or falls back to the active tab's pwd).
    private func resolvedProjectKey(workDir: String?) -> String {
        AgentMemoryStore.key(for: workDir ?? resolvedWorkDir())
    }

    private func handleCompactMemories(id: JSONRPCId, arguments: [String: AnyCodable]?) -> (statusCode: Int, body: Data?) {
        let workDir = arguments?["work_dir"]?.stringValue
        let projectKey = resolvedProjectKey(workDir: workDir)

        let beforeStats = AgentMemoryStore.shared.stats(projectKey: projectKey)
        AgentMemoryStore.shared.compact(projectKey: projectKey)
        let afterStats = AgentMemoryStore.shared.stats(projectKey: projectKey)

        let result: [String: Any] = [
            "compacted": true,
            "before_count": beforeStats.totalCount,
            "after_count": afterStats.totalCount,
            "pruned": beforeStats.totalCount - afterStats.totalCount,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: result),
              let text = String(data: data, encoding: .utf8) else {
            return toolSuccess(id: id, text: "{\"compacted\":true}")
        }
        return toolSuccess(id: id, text: text)
    }

    /// Applies an optional namespace prefix to a memory key.
    /// `namespacedKey("foo", namespace: "orchestrator")` → `"orchestrator/foo"`
    /// `namespacedKey("foo", namespace: nil)` → `"foo"`
    private func namespacedKey(_ key: String, namespace: String?) -> String {
        guard let ns = namespace, !ns.isEmpty else { return key }
        return "\(ns)/\(key)"
    }

    /// Returns the most recent `ShellErrorEvent` across all tabs (or the specific tab if given).
    private func findLastError(tabID: UUID?) -> ShellErrorEvent? {
        let session = TerminalControlBridge.shared.delegate?.terminalWindowSession
        let allTabs = session?.groups.flatMap(\.tabs) ?? []
        let candidates = tabID != nil
            ? allTabs.filter { $0.id == tabID }
            : allTabs
        return candidates
            .compactMap(\.lastShellError)
            .sorted { $0.timestamp > $1.timestamp }
            .first
    }

    // MARK: - Session Audit

    private func handleGetSessionSummary(id: JSONRPCId) -> (statusCode: Int, body: Data?) {
        let summary: [String: Any] = SessionAuditLogger.shared.summaryDict()
        guard let data = try? JSONSerialization.data(withJSONObject: summary),
              let text = String(data: data, encoding: .utf8) else {
            return toolSuccess(id: id, text: "{}")
        }
        return toolSuccess(id: id, text: text)
    }

    // MARK: - Agent Handoff

    private func handleGetLastHandoff(id: JSONRPCId, arguments: [String: AnyCodable]?) -> (statusCode: Int, body: Data?) {
        let workDir = arguments?["work_dir"]?.stringValue ?? resolvedWorkDir()
        let projectKey = AgentMemoryStore.key(for: workDir)
        guard let handoff = AgentMemoryStore.shared.lastHandoff(projectKey: projectKey) else {
            return toolSuccess(id: id, text: "{\"found\":false}")
        }
        let result: [String: Any] = [
            "found": true,
            "summary": handoff.value,
            "age": handoff.age,
            "updated_at": Self.iso8601.string(from: handoff.updatedAt),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: result),
              let text = String(data: data, encoding: .utf8) else {
            return toolSuccess(id: id, text: "{\"found\":false}")
        }
        return toolSuccess(id: id, text: text)
    }

    // MARK: - Agent Environment

    /// Returns a self-orientation snapshot: where the agent is, what it can do,
    /// and what the current CTerm environment looks like.
    private func handleGetAgentEnvironment(
        id: JSONRPCId,
        arguments: [String: AnyCodable]?
    ) -> (statusCode: Int, body: Data?) {
        let workDir = arguments?["work_dir"]?.stringValue ?? resolvedWorkDir()

        var env: [String: Any] = [:]

        // MCP server connection info
        env["mcp_server"] = [
            "port": CTermMCPServer.shared.port,
            "host": "127.0.0.1",
            "protocol": "HTTP/JSON-RPC",
            "auth": "Bearer token (injected by CTerm into your environment as CTERM_MCP_TOKEN)",
        ] as [String: Any]

        // Browser server status
        let browser = BrowserServer.shared
        if browser.isRunning {
            env["browser_server"] = [
                "running": true,
                "port": browser.port,
                "host": "127.0.0.1",
                "note": "Use 'cterm browser' CLI or browser_* MCP tools for web automation",
            ] as [String: Any]
        } else {
            env["browser_server"] = ["running": false] as [String: Any]
        }

        // Which pane/tab the agent is likely running in (match by pwd)
        if let delegate = TerminalControlBridge.shared.delegate {
            let session = delegate.terminalWindowSession
            let allTabs = session.groups.flatMap(\.tabs)
            if let matchingTab = allTabs.first(where: { $0.pwd == workDir }) {
                var paneCtx: [String: Any] = [
                    "tab_id": matchingTab.id.uuidString,
                    "tab_title": matchingTab.title,
                    "pwd": matchingTab.pwd ?? workDir,
                ]
                if let focusedID = matchingTab.splitTree.focusedLeafID {
                    paneCtx["pane_id"] = focusedID.uuidString
                }
                let paneCount = matchingTab.splitTree.allLeafIDs().count
                if paneCount > 1 {
                    paneCtx["split_pane_count"] = paneCount
                    paneCtx["note"] = "This tab has \(paneCount) panes. Use get_workspace_state for full layout."
                }
                env["my_pane"] = paneCtx
            }
        }

        // Active peers
        let peers = MainActor.assumeIsolated { IPCAgentState.shared.peers }
        if !peers.isEmpty {
            env["active_peers"] = peers.map { p -> [String: Any] in
                [
                    "name": p.name,
                    "role": p.role,
                    "status": AgentStatus.infer(from: p).label,
                ]
            }
        }

        // Capabilities manifest — what's available in this CTerm build
        env["capabilities"] = [
            "terminal_control": true,
            "split_panes": true,
            "browser_automation": browser.isRunning,
            "agent_memory": true,
            "task_queue": true,
            "delegation": true,
            "git_integration": true,
            "test_runner": true,
            "peer_ipc": true,
            "desktop_notifications": true,
            "terminal_search": true,
        ] as [String: Any]

        // Lightweight project context (no full CLAUDE.md — use get_project_context for that)
        let ctx = ProjectContextProvider.gather(workDir: workDir)
        if let branch = ctx["branch"] as? String { env["branch"] = branch }
        if let dirty = ctx["dirty_files"] as? [String], !dirty.isEmpty { env["dirty_files"] = dirty }
        if let stats = ctx["memory_stats"] as? [String: Any] { env["memory_stats"] = stats }
        if let tests = ctx["failing_tests"] as? [String], !tests.isEmpty { env["failing_tests"] = tests }
        env["cwd"] = workDir

        guard let data = try? JSONSerialization.data(withJSONObject: env),
              let text = String(data: data, encoding: .utf8) else {
            return toolSuccess(id: id, text: "{\"cwd\":\"\(workDir)\"}")
        }
        return toolSuccess(id: id, text: text)
    }

    // MARK: - Terminal Search

    private func handleSearchTerminalOutput(id: JSONRPCId, arguments: [String: AnyCodable]?) -> (statusCode: Int, body: Data?) {
        guard let query = arguments?["query"]?.stringValue, !query.isEmpty else {
            return toolError(id: id, text: "query is required")
        }
        let paneID = arguments?["pane_id"]?.stringValue
        let limit  = (arguments?["limit"]?.rawValue as? Int).map { min($0, 100) } ?? 30

        let results = TerminalSearchIndex.shared.search(query: query, paneID: paneID, limit: limit)
        let dicts = results.map { r -> [String: Any] in
            [
                "pane_id":    r.paneID,
                "pane_title": r.paneTitle,
                "timestamp":  Self.iso8601.string(from: r.timestamp),
                "line":       r.line
            ]
        }
        let payload: [String: Any] = ["query": query, "count": dicts.count, "results": dicts]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else {
            return toolSuccess(id: id, text: "{\"count\":0,\"results\":[]}")
        }
        return toolSuccess(id: id, text: text)
    }

    // MARK: - Wait For Pane Idle

    /// Polls the target pane's viewport text every 500 ms looking for a shell prompt
    /// on the last non-empty line. Returns when the shell is idle or the timeout expires.
    private func handleWaitForPaneIdle(id: JSONRPCId, arguments: [String: AnyCodable]?) async -> (statusCode: Int, body: Data?) {
        let paneIDStr = arguments?["pane_id"]?.stringValue
        let rawTimeout = (arguments?["timeout_seconds"]?.rawValue as? Double) ?? 30.0
        let timeoutSeconds = min(rawTimeout, 300.0)

        let started = Date()

        // Shell-prompt suffixes matching ShellErrorMonitor.
        let promptSuffixes: [String] = ["$ ", "% ", "❯ ", "➜ ", "> ", "λ ", "# "]

        func isIdle() -> Bool {
            guard let delegate = TerminalControlBridge.shared.delegate else { return false }
            let session = delegate.terminalWindowSession
            let allTabs = session.groups.flatMap(\.tabs)

            // Find the target pane controller.
            let controller: GhosttySurfaceController?
            if let paneIDStr, let paneID = UUID(uuidString: paneIDStr) {
                controller = allTabs.lazy.compactMap { tab in
                    tab.registry.controller(for: paneID)
                }.first
            } else {
                // No pane_id specified — use the focused pane of the active tab.
                let activeTab = session.activeGroup?.activeTab
                if let leafID = activeTab?.splitTree.focusedLeafID {
                    controller = activeTab?.registry.controller(for: leafID)
                } else {
                    controller = nil
                }
            }

            guard let ctrl = controller,
                  let surface = ctrl.surface,
                  let text = GhosttyFFI.surfaceReadViewportText(surface) else {
                return false
            }

            let lines = text.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            guard let lastLine = lines.last else { return false }
            return promptSuffixes.contains { lastLine.hasSuffix($0) || lastLine.contains($0) }
        }

        // Poll every 500 ms until idle or timed out.
        let pollIntervalNs: UInt64 = 500_000_000
        while true {
            if isIdle() {
                let elapsed = Date().timeIntervalSince(started)
                let result: [String: Any] = ["idle": true, "elapsed_seconds": elapsed]
                guard let data = try? JSONSerialization.data(withJSONObject: result),
                      let text = String(data: data, encoding: .utf8) else {
                    return toolSuccess(id: id, text: "{\"idle\":true}")
                }
                return toolSuccess(id: id, text: text)
            }

            let elapsed = Date().timeIntervalSince(started)
            if elapsed >= timeoutSeconds {
                let result: [String: Any] = ["idle": false, "timed_out": true, "elapsed_seconds": elapsed]
                guard let data = try? JSONSerialization.data(withJSONObject: result),
                      let text = String(data: data, encoding: .utf8) else {
                    return toolSuccess(id: id, text: "{\"idle\":false,\"timed_out\":true}")
                }
                return toolSuccess(id: id, text: text)
            }

            try? await Task.sleep(nanoseconds: pollIntervalNs)
        }
    }

    // MARK: - Project Context

    private func handleGetProjectContext(id: JSONRPCId, arguments: [String: AnyCodable]?) -> (statusCode: Int, body: Data?) {
        let workDir = arguments?["work_dir"]?.stringValue ?? resolvedWorkDir()
        let intent = arguments?["intent"]?.stringValue
        let ctx = ProjectContextProvider.gather(workDir: workDir, intent: intent)
        guard let data = try? JSONSerialization.data(withJSONObject: ctx),
              let text = String(data: data, encoding: .utf8) else {
            return toolSuccess(id: id, text: "{\"cwd\":\"\(workDir)\"}")
        }
        return toolSuccess(id: id, text: text)
    }

    /// Active tab's pwd, resolved on the main actor.
    private func resolvedWorkDir() -> String {
        let pwd = TerminalControlBridge.shared.delegate?.activeTabPwd
        return pwd ?? FileManager.default.currentDirectoryPath
    }

    // MARK: - Test Runner

    private func handleGetTestResults(id: JSONRPCId) -> (statusCode: Int, body: Data?) {
        let store = TestRunnerStore.shared
        let failures = store.failures.map { f -> [String: Any] in
            ["name": f.name, "duration": f.duration as Any]
        }
        let result: [String: Any] = [
            "pass_count": store.passCount,
            "fail_count": store.failCount,
            "is_running": store.isRunning,
            "failures": failures,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: result),
              let text = String(data: data, encoding: .utf8) else {
            return toolSuccess(id: id, text: "{\"pass_count\":0,\"fail_count\":0,\"is_running\":false,\"failures\":[]}")
        }
        return toolSuccess(id: id, text: text)
    }

    private func handleRunTests(id: JSONRPCId, arguments: [String: AnyCodable]?) -> (statusCode: Int, body: Data?) {
        let command = arguments?["command"]?.stringValue
        let workDir = arguments?["work_dir"]?.stringValue

        // CTermMCPServer is @MainActor — mutate TestRunnerStore directly without
        // re-dispatching to main, which would return before the store is updated.
        let store = TestRunnerStore.shared
        if let wd = workDir { store.workDir = wd }
        store.run(command: command)

        let result: [String: Any] = ["started": true, "command": command as Any]
        guard let data = try? JSONSerialization.data(withJSONObject: result),
              let text = String(data: data, encoding: .utf8) else {
            return toolSuccess(id: id, text: "{\"started\":true}")
        }
        return toolSuccess(id: id, text: text)
    }

    // MARK: - Response Helpers

    private func unauthorizedResponse() -> (statusCode: Int, body: Data?) {
        let dict: [String: Any] = ["error": "Unauthorized"]
        let data = try? JSONSerialization.data(withJSONObject: dict)
        return (401, data)
    }

    private func toolSuccess(id: JSONRPCId, text: String) -> (statusCode: Int, body: Data?) {
        let content = [MCPContent(type: "text", text: text)]
        let resp = MCPRouter.buildToolCallResponse(id: id, content: content, isError: false)
        return (200, encode(resp))
    }

    private func toolError(id: JSONRPCId, text: String) -> (statusCode: Int, body: Data?) {
        let content = [MCPContent(type: "text", text: text)]
        let resp = MCPRouter.buildToolCallResponse(id: id, content: content, isError: true)
        return (200, encode(resp))
    }

    private func encode(_ response: JSONRPCResponse) -> Data? {
        try? JSONEncoder().encode(response)
    }

    // MARK: - Serialization Helpers

    private func peerToDict(_ peer: Peer) -> [String: Any] {
        [
            "id": peer.id.uuidString,
            "name": peer.name,
            "role": peer.role,
            "lastSeen": Self.iso8601.string(from: peer.lastSeen),
            "registeredAt": Self.iso8601.string(from: peer.registeredAt),
        ]
    }

    private func messageToDict(_ message: Message, fromName: String? = nil) -> [String: Any] {
        var dict: [String: Any] = [
            "id": message.id.uuidString,
            "from": message.from.uuidString,
            "to": message.to.uuidString,
            "content": message.content,
            "timestamp": Self.iso8601.string(from: message.timestamp),
        ]
        if let fromName { dict["fromName"] = fromName }
        if let topic = message.topic { dict["topic"] = topic }
        if let replyTo = message.replyTo { dict["replyTo"] = replyTo }
        return dict
    }

    // MARK: - AnyCodable Extraction Helpers

    /// Extract a string value from an AnyCodable dictionary.
    private func extractString(_ dict: [String: AnyCodable], _ key: String) -> String? {
        dict[key]?.stringValue
    }

    /// Extract a [String: AnyCodable] dictionary from an AnyCodable value at the given key.
    private func extractDict(_ dict: [String: AnyCodable], _ key: String) -> [String: AnyCodable]? {
        dict[key]?.anyCodableDictionaryValue
    }

    /// Extract the client name from an initialize request's clientInfo.
    private func extractClientName(from params: [String: AnyCodable]?) -> String? {
        guard let params,
              let clientInfoDict = extractDict(params, "clientInfo"),
              let name = clientInfoDict["name"]?.stringValue,
              !name.isEmpty else {
            return nil
        }
        return name
    }
}
