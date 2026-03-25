//
//  CalyxMCPServer.swift
//  Calyx
//
//  MCP server: accepts JSON-RPC over TCP, authenticates via bearer token,
//  routes to MCPRouter / IPCStore for IPC tool calls.
//

import AppKit
import Foundation
import Network

@MainActor
final class CalyxMCPServer {

    static let shared = CalyxMCPServer()

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
                nl.start(queue: .main)

                self.listener = nl
                self.port = tryPort
                self.isRunning = true
                self.peerRegistrationTask = Task {
                    let peer = await self.store.registerPeer(name: "calyx-app", role: "review-ui")
                    self.appPeerID = peer.id
                }
                return
            } catch {
                lastError = error
                continue
            }
        }

        throw lastError ?? NSError(
            domain: "CalyxMCPServer",
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
            // Auto-register the connecting client as a peer
            let clientName = extractClientName(from: request.params) ?? "claude-code"
            let peer = await store.registerPeer(name: clientName, role: "claude-code")
            let resp = MCPRouter.buildInitializeResponse(id: requestId, peerID: peer.id)
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

        default:
            return toolError(id: id, text: "Unknown tool: \(toolName)")
        }
    }

    // MARK: - Tool Handlers

    private func handleRegisterPeer(
        id: JSONRPCId,
        arguments: [String: Any]?
    ) async -> (statusCode: Int, body: Data?) {
        let name = (arguments?["name"] as? String) ?? ""
        let role = (arguments?["role"] as? String) ?? ""
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
        let autoInject = UserDefaults.standard.object(forKey: "CalyxAutoInjectContext") as? Bool ?? true
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
        arguments: [String: Any]?
    ) async -> (statusCode: Int, body: Data?) {
        guard let fromStr = arguments?["from"] as? String,
              let toStr = arguments?["to"] as? String,
              let content = arguments?["content"] as? String,
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

        let topic = arguments?["topic"] as? String
        let replyTo = arguments?["reply_to"] as? String

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
        arguments: [String: Any]?
    ) async -> (statusCode: Int, body: Data?) {
        guard let fromStr = arguments?["from"] as? String,
              let content = arguments?["content"] as? String,
              let fromUUID = UUID(uuidString: fromStr) else {
            return toolError(id: id, text: "Missing or invalid from/content")
        }

        let topic = arguments?["topic"] as? String

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
        arguments: [String: Any]?
    ) async -> (statusCode: Int, body: Data?) {
        guard let peerStr = arguments?["peer_id"] as? String,
              let peerUUID = UUID(uuidString: peerStr) else {
            return toolError(id: id, text: "Missing or invalid peer_id")
        }

        // Parse optional 'since' cursor
        let since: Date? = (arguments?["since"] as? String).flatMap { Self.iso8601.date(from: $0) }
        let topic = arguments?["topic"] as? String

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
        arguments: [String: Any]?
    ) async -> (statusCode: Int, body: Data?) {
        guard let peerStr = arguments?["peer_id"] as? String,
              let peerUUID = UUID(uuidString: peerStr),
              let messageIdStrings = arguments?["message_ids"] as? [String] else {
            return toolError(id: id, text: "Missing or invalid peer_id/message_ids")
        }

        let messageUUIDs = messageIdStrings.compactMap { UUID(uuidString: $0) }
        await store.ackMessages(ids: messageUUIDs, for: peerUUID)
        let json = "{\"acknowledged\":\(messageUUIDs.count)}"
        return toolSuccess(id: id, text: json)
    }

    private func handleGetPeerStatus(
        id: JSONRPCId,
        arguments: [String: Any]?
    ) async -> (statusCode: Int, body: Data?) {
        guard let peerStr = arguments?["peer_id"] as? String,
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
        arguments: [String: Any]?
    ) async -> (statusCode: Int, body: Data?) {
        guard let peerStr = arguments?["peer_id"] as? String,
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

        await MainActor.run {
            FileChangeStore.shared.report(path: path, workDir: workDir, peerID: peerID, peerName: peerName)
        }
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
        Task { @MainActor in
            TaskQueueStore.shared.enqueue(prompt, targetPeerName: targetPeer, at: position)
        }
        return toolSuccess(id: id, text: "{\"queued\":true,\"pending\":\(TaskQueueStore.shared.pendingCount + 1)}")
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
        Task { @MainActor in
            TaskQueueStore.shared.completeCurrent(result: result)
        }
        return toolSuccess(id: id, text: "{\"advanced\":true}")
    }

    private func handleClearQueue(id: JSONRPCId) -> (statusCode: Int, body: Data?) {
        Task { @MainActor in
            TaskQueueStore.shared.clearPending()
        }
        return toolSuccess(id: id, text: "{\"cleared\":true}")
    }

    private func handleGetLastError(id: JSONRPCId, arguments: [String: Any]?) -> (statusCode: Int, body: Data?) {
        let filterTabID = (arguments?["tab_id"] as? String).flatMap { UUID(uuidString: $0) }

        let result: [String: Any]
        if let event = findLastError(tabID: filterTabID) {
            result = [
                "found": true,
                "tab_id": event.tabID.uuidString,
                "tab_title": event.tabTitle,
                "snippet": event.snippet,
                "timestamp": ISO8601DateFormatter().string(from: event.timestamp),
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

    private func handleRemember(id: JSONRPCId, arguments: [String: Any]?) -> (statusCode: Int, body: Data?) {
        guard let key = arguments?["key"] as? String, !key.isEmpty,
              let value = arguments?["value"] as? String, !value.isEmpty else {
            return toolError(id: id, text: "remember requires non-empty 'key' and 'value'")
        }
        let ttlDays = arguments?["ttl_days"] as? Int
        let workDir = arguments?["work_dir"] as? String
        let projectKey = resolvedProjectKey(workDir: workDir)

        let entry = AgentMemoryStore.shared.remember(
            projectKey: projectKey,
            key: key,
            value: value,
            ttlDays: ttlDays
        )
        NotificationCenter.default.post(name: .agentMemoryChanged, object: nil)

        let result: [String: Any] = [
            "stored": true,
            "key": entry.key,
            "project_key": projectKey,
            "expires_at": entry.expiresAt.map { ISO8601DateFormatter().string(from: $0) } as Any,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: result),
              let text = String(data: data, encoding: .utf8) else {
            return toolSuccess(id: id, text: "{\"stored\":true}")
        }
        return toolSuccess(id: id, text: text)
    }

    private func handleRecall(id: JSONRPCId, arguments: [String: Any]?) -> (statusCode: Int, body: Data?) {
        let query = arguments?["query"] as? String ?? ""
        let workDir = arguments?["work_dir"] as? String
        let projectKey = resolvedProjectKey(workDir: workDir)

        let entries = AgentMemoryStore.shared.recall(projectKey: projectKey, query: query)
        let list = entries.map { e -> [String: Any] in
            var item: [String: Any] = ["key": e.key, "value": e.value, "age": e.age]
            if let exp = e.expiresAt { item["expires_at"] = ISO8601DateFormatter().string(from: exp) }
            return item
        }
        let result: [String: Any] = ["project_key": projectKey, "count": list.count, "memories": list]
        guard let data = try? JSONSerialization.data(withJSONObject: result),
              let text = String(data: data, encoding: .utf8) else {
            return toolSuccess(id: id, text: "{\"count\":0,\"memories\":[]}")
        }
        return toolSuccess(id: id, text: text)
    }

    private func handleForget(id: JSONRPCId, arguments: [String: Any]?) -> (statusCode: Int, body: Data?) {
        guard let key = arguments?["key"] as? String, !key.isEmpty else {
            return toolError(id: id, text: "forget requires 'key'")
        }
        let workDir = arguments?["work_dir"] as? String
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

    private func handleListMemories(id: JSONRPCId, arguments: [String: Any]?) -> (statusCode: Int, body: Data?) {
        let workDir = arguments?["work_dir"] as? String
        let projectKey = resolvedProjectKey(workDir: workDir)

        let entries = AgentMemoryStore.shared.listAll(projectKey: projectKey)
        let list = entries.map { e -> [String: Any] in
            var item: [String: Any] = ["key": e.key, "value": e.value, "age": e.age, "updated_at": ISO8601DateFormatter().string(from: e.updatedAt)]
            if let exp = e.expiresAt { item["expires_at"] = ISO8601DateFormatter().string(from: exp) }
            return item
        }
        let result: [String: Any] = ["project_key": projectKey, "count": list.count, "memories": list]
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

    /// Returns the most recent `ShellErrorEvent` across all tabs (or the specific tab if given).
    private func findLastError(tabID: UUID?) -> ShellErrorEvent? {
        // This is called from a network thread but reads @MainActor Tab properties.
        // We use a synchronous dispatch to the main actor for a brief read.
        var result: ShellErrorEvent?
        DispatchQueue.main.sync {
            let session = TerminalControlBridge.shared.delegate?.terminalWindowSession
            let allTabs = session?.groups.flatMap(\.tabs) ?? []
            let candidates = tabID != nil
                ? allTabs.filter { $0.id == tabID }
                : allTabs
            result = candidates
                .compactMap(\.lastShellError)
                .sorted { $0.timestamp > $1.timestamp }
                .first
        }
        return result
    }

    // MARK: - Session Audit

    private func handleGetSessionSummary(id: JSONRPCId) -> (statusCode: Int, body: Data?) {
        var summary: [String: Any] = [:]
        DispatchQueue.main.sync {
            summary = SessionAuditLogger.shared.summaryDict()
        }
        guard let data = try? JSONSerialization.data(withJSONObject: summary),
              let text = String(data: data, encoding: .utf8) else {
            return toolSuccess(id: id, text: "{}")
        }
        return toolSuccess(id: id, text: text)
    }

    // MARK: - Terminal Search

    private func handleSearchTerminalOutput(id: JSONRPCId, arguments: [String: Any]?) -> (statusCode: Int, body: Data?) {
        guard let query = arguments?["query"] as? String, !query.isEmpty else {
            return toolError(id: id, text: "query is required")
        }
        let paneID = arguments?["pane_id"] as? String
        let limit  = (arguments?["limit"] as? Int).map { min($0, 100) } ?? 30

        let results = TerminalSearchIndex.shared.search(query: query, paneID: paneID, limit: limit)
        let dicts = results.map { r -> [String: Any] in
            [
                "pane_id":    r.paneID,
                "pane_title": r.paneTitle,
                "timestamp":  ISO8601DateFormatter().string(from: r.timestamp),
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

    // MARK: - Project Context

    private func handleGetProjectContext(id: JSONRPCId, arguments: [String: Any]?) -> (statusCode: Int, body: Data?) {
        let workDir = arguments?["work_dir"] as? String ?? resolvedWorkDir()
        let ctx = ProjectContextProvider.gather(workDir: workDir)
        guard let data = try? JSONSerialization.data(withJSONObject: ctx),
              let text = String(data: data, encoding: .utf8) else {
            return toolSuccess(id: id, text: "{\"cwd\":\"\(workDir)\"}")
        }
        return toolSuccess(id: id, text: text)
    }

    /// Active tab's pwd, resolved on the main thread.
    private func resolvedWorkDir() -> String {
        var pwd: String?
        DispatchQueue.main.sync { pwd = TerminalControlBridge.shared.delegate?.activeTabPwd }
        return pwd ?? FileManager.default.currentDirectoryPath
    }

    // MARK: - Test Runner

    private func handleGetTestResults(id: JSONRPCId) -> (statusCode: Int, body: Data?) {
        var result: [String: Any] = [:]
        DispatchQueue.main.sync {
            let store = TestRunnerStore.shared
            let failures = store.failures.map { f -> [String: Any] in
                ["name": f.name, "duration": f.duration as Any]
            }
            result = [
                "pass_count": store.passCount,
                "fail_count": store.failCount,
                "is_running": store.isRunning,
                "failures": failures,
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: result),
              let text = String(data: data, encoding: .utf8) else {
            return toolSuccess(id: id, text: "{\"pass_count\":0,\"fail_count\":0,\"is_running\":false,\"failures\":[]}")
        }
        return toolSuccess(id: id, text: text)
    }

    private func handleRunTests(id: JSONRPCId, arguments: [String: Any]?) -> (statusCode: Int, body: Data?) {
        let command = arguments?["command"] as? String
        let workDir = arguments?["work_dir"] as? String

        DispatchQueue.main.async {
            let store = TestRunnerStore.shared
            if let wd = workDir { store.workDir = wd }
            store.run(command: command)
        }

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
