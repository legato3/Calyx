import Foundation

enum ComposeAssistantMode: String, CaseIterable, Identifiable, Sendable {
    case shell
    case ollamaCommand
    case ollamaAgent
    /// Claude Subscription-backed agent workflow via the local Claude client.
    case claudeAgent

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .shell: return "Shell"
        case .ollamaCommand: return "Ollama"
        case .ollamaAgent: return "Local Agent"
        case .claudeAgent: return "Agent"
        }
    }

    var placeholderText: String {
        switch self {
        case .shell:
            return "Type a shell command..."
        case .ollamaCommand:
            return "Ask Ollama to suggest or check a terminal command..."
        case .ollamaAgent:
            return "Describe the task for the local agent..."
        case .claudeAgent:
            return "Ask Agent (Claude Subscription) to build, fix, or explain something..."
        }
    }

    /// Whether this mode routes to an AI agent (not raw shell).
    var isAgentMode: Bool {
        switch self {
        case .shell: return false
        case .ollamaCommand, .ollamaAgent, .claudeAgent: return true
        }
    }

    /// Whether this mode starts and manages an inline agent session.
    var startsAgentSession: Bool {
        switch self {
        case .ollamaAgent, .claudeAgent:
            return true
        case .shell, .ollamaCommand:
            return false
        }
    }
}

enum OllamaSuggestionBehavior: String, CaseIterable, Identifiable, Sendable {
    case suggestOnly
    case autofill
    case autorunSafe

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .suggestOnly: return "Suggest Only"
        case .autofill: return "Suggest + Autofill"
        case .autorunSafe: return "Autorun Safe"
        }
    }

    var helpText: String {
        switch self {
        case .suggestOnly:
            return "Keep suggestions in history until you explicitly load or run them."
        case .autofill:
            return "Load high-confidence runnable suggestions into the compose bar automatically."
        case .autorunSafe:
            return "Automatically run low-risk suggestions, otherwise fall back to autofill."
        }
    }

    static let defaultValue: Self = .autofill

    static func current(defaults: UserDefaults = .standard) -> Self {
        guard let raw = defaults.string(forKey: AppStorageKeys.ollamaSuggestionBehavior),
              let behavior = Self(rawValue: raw) else {
            return defaultValue
        }
        return behavior
    }
}

struct LoadedSuggestionContext: Sendable {
    let entryID: UUID
    let previousDraft: String
    let previousMode: ComposeAssistantMode
    let previousModeLocked: Bool
}

// MARK: - Input Intent Detection

/// Classifies a text input as likely shell command or agent prompt.
enum InputIntent: Equatable {
    case shell
    case agent
    case ambiguous

    var label: String {
        switch self {
        case .shell: return "shell"
        case .agent: return "agent"
        case .ambiguous: return ""
        }
    }

    var color: String {
        switch self {
        case .shell: return "green"
        case .agent: return "purple"
        case .ambiguous: return "secondary"
        }
    }
}

enum InputIntentDetector {
    // Patterns that strongly suggest a shell command
    private static let shellPrefixes: [String] = [
        "ls", "cd", "pwd", "cat", "echo", "grep", "find", "rm", "mv", "cp",
        "mkdir", "touch", "chmod", "chown", "sudo", "git", "npm", "yarn",
        "swift", "xcodebuild", "make", "cargo", "go ", "python", "node",
        "curl", "wget", "ssh", "scp", "tar", "zip", "unzip", "brew",
        "docker", "kubectl", "terraform", "aws", "open ", "./", "../",
        "export ", "source ", "which ", "type ", "env ", "kill ", "ps ",
    ]

    // Words that strongly suggest a natural language agent prompt
    private static let agentKeywords: [String] = [
        "please", "can you", "could you", "help me", "write", "create",
        "build", "implement", "add", "fix", "refactor", "explain",
        "what is", "how do", "why does", "show me", "generate",
        "make a", "make the", "update", "change", "modify", "delete",
        "debug", "test", "deploy", "analyze", "analyse", "review",
        "summarize", "summarise", "describe", "list all", "find all",
        "i want", "i need", "i'd like", "let's", "let me",
    ]

    static func detect(_ text: String) -> InputIntent {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .ambiguous }

        let lower = trimmed.lowercased()

        // Multi-word or sentence-like → likely agent
        let wordCount = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.count
        if wordCount >= 6 { return .agent }

        // Starts with a shell prefix → shell
        for prefix in shellPrefixes {
            if lower.hasPrefix(prefix) { return .shell }
        }

        // Contains agent keywords → agent
        for keyword in agentKeywords {
            if lower.contains(keyword) { return .agent }
        }

        // Looks like a path or flag → shell
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") || trimmed.hasPrefix("-") {
            return .shell
        }

        // Contains spaces but no shell prefix → lean agent
        if wordCount >= 3 { return .agent }

        return .ambiguous
    }
}

enum ComposeAssistantEntryKind: String, Sendable {
    case shellDispatch
    case commandSuggestion
    case explanation
    case fixSuggestion

    var title: String {
        switch self {
        case .shellDispatch: return "Command"
        case .commandSuggestion: return "Suggestion"
        case .explanation: return "Explanation"
        case .fixSuggestion: return "Fix"
        }
    }
}

enum ComposeAssistantEntryStatus: String, Sendable {
    case pending
    case ready
    case failed
    case inserted
    case ran

    var label: String {
        switch self {
        case .pending: return "Thinking"
        case .ready: return "Ready"
        case .failed: return "Failed"
        case .inserted: return "Loaded"
        case .ran: return "Sent"
        }
    }
}

struct ComposeAssistantEntry: Identifiable, Sendable {
    let id: UUID
    let kind: ComposeAssistantEntryKind
    let prompt: String
    var response: String
    var command: String?
    var contextSnippet: String?
    var status: ComposeAssistantEntryStatus
    var errorMessage: String?
    let createdAt: Date

    var runnableCommand: String? {
        guard let command else { return nil }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("NOTE:") else { return nil }
        return trimmed
    }

    /// User-visible prompt with any injected context envelope stripped out.
    var displayPrompt: String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if let contextRange = trimmed.range(of: "\n\n<cterm_agent_context>") {
            return String(trimmed[..<contextRange.lowerBound])
        }
        return trimmed
    }

    var primaryText: String {
        if let errorMessage, !errorMessage.isEmpty {
            return errorMessage
        }
        if !response.isEmpty {
            return response
        }
        if let command, !command.isEmpty {
            return command
        }
        return prompt
    }

    var usesMonospacedBody: Bool {
        switch kind {
        case .shellDispatch, .commandSuggestion, .fixSuggestion:
            return true
        case .explanation:
            return false
        }
    }

    var canInsert: Bool {
        switch kind {
        case .commandSuggestion, .fixSuggestion:
            return runnableCommand != nil
        case .shellDispatch, .explanation:
            return false
        }
    }

    var canRun: Bool {
        switch kind {
        case .shellDispatch, .commandSuggestion, .fixSuggestion:
            return runnableCommand != nil
        case .explanation:
            return false
        }
    }

    var canExplain: Bool {
        switch kind {
        case .shellDispatch, .commandSuggestion, .fixSuggestion:
            return true
        case .explanation:
            return false
        }
    }

    var canFix: Bool {
        switch kind {
        case .shellDispatch, .commandSuggestion, .fixSuggestion:
            return true
        case .explanation:
            return false
        }
    }
}

@MainActor
@Observable
final class ComposeAssistantState {
    private static let maxEntries = 12

    var mode: ComposeAssistantMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: AppStorageKeys.composeAssistantMode)
            if mode.startsAgentSession, lastAgentMode != mode {
                lastAgentMode = mode
            }
        }
    }

    /// When true, Return + the mode chip strictly respect `mode`. When false
    /// (default), `effectiveMode(for:)` picks shell vs agent from what the user
    /// is typing, in real time.
    var isModeLocked: Bool {
        didSet {
            UserDefaults.standard.set(isModeLocked, forKey: AppStorageKeys.composeModeLocked)
        }
    }

    /// Preferred agent backend used when auto-routing detects an agent prompt.
    var lastAgentMode: ComposeAssistantMode {
        didSet {
            UserDefaults.standard.set(lastAgentMode.rawValue, forKey: AppStorageKeys.composeLastAgentMode)
        }
    }

    var draftText: String = ""
    var interactions: [ComposeAssistantEntry] = []
    var loadedSuggestionContext: LoadedSuggestionContext?
    /// Called whenever draftText changes — used by CTermWindowController to drive next-command prediction.
    var onDraftTextChanged: ((String) -> Void)?

    /// Transient: set to `true` right after an auto-routed agent dispatch, so
    /// the compose bar can show a one-shot "sent to agent" hint. Consumer
    /// resets this after acknowledging.
    var showAutoRouteHint: Bool = false

    /// Transient: set to `true` when the overlay was opened via the `#`
    /// NL-mode prefix. While set, the mode is locked to an agent backend and
    /// the compose bar shows a "# triggered" indicator. Cleared on send or
    /// dismiss so subsequent opens behave normally.
    var isForcedAgentMode: Bool = false

    init() {
        let raw = UserDefaults.standard.string(forKey: AppStorageKeys.composeAssistantMode) ?? ComposeAssistantMode.shell.rawValue
        let resolvedMode = ComposeAssistantMode(rawValue: raw) ?? .shell
        self.mode = resolvedMode
        // Default unlocked (smart per-prompt). Users who previously lived with
        // a non-shell sticky mode get migrated to locked so their preference
        // still holds on first launch.
        if UserDefaults.standard.object(forKey: AppStorageKeys.composeModeLocked) == nil {
            self.isModeLocked = (resolvedMode != .shell)
        } else {
            self.isModeLocked = UserDefaults.standard.bool(forKey: AppStorageKeys.composeModeLocked)
        }
        let lastAgentRaw = UserDefaults.standard.string(forKey: AppStorageKeys.composeLastAgentMode)
        if let lastAgentRaw,
           let parsed = ComposeAssistantMode(rawValue: lastAgentRaw),
           parsed.startsAgentSession {
            self.lastAgentMode = parsed
        } else {
            self.lastAgentMode = .claudeAgent
        }
    }

    /// The mode dispatch should actually use for the current draft text.
    /// When locked, just returns `mode`. When unlocked, consults
    /// InputIntentDetector and routes agent-like text to `lastAgentMode`.
    func effectiveMode(for draftText: String) -> ComposeAssistantMode {
        if isModeLocked { return mode }
        let trimmed = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .shell }
        switch InputIntentDetector.detect(trimmed) {
        case .shell, .ambiguous: return .shell
        case .agent:             return lastAgentMode
        }
    }

    var placeholderText: String { effectiveMode(for: draftText).placeholderText }
    var isBusy: Bool { interactions.contains(where: { $0.status == .pending }) }
    var loadedSuggestionEntry: ComposeAssistantEntry? {
        guard let loadedSuggestionContext else { return nil }
        return entry(id: loadedSuggestionContext.entryID)
    }

    /// Auto-detected intent for the current draft text (only meaningful in shell mode).
    var detectedIntent: InputIntent {
        guard mode == .shell, !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .ambiguous
        }
        return InputIntentDetector.detect(draftText)
    }
    var latestRunnableEntry: ComposeAssistantEntry? {
        interactions.first(where: { $0.canRun || $0.canExplain || $0.canFix })
    }

    func setDraftText(_ text: String) {
        if draftText != text {
            draftText = text
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                clearLoadedSuggestionContext()
            }
            onDraftTextChanged?(text)
        }
    }

    @discardableResult
    func addEntry(
        kind: ComposeAssistantEntryKind,
        prompt: String,
        response: String = "",
        command: String? = nil,
        contextSnippet: String? = nil,
        status: ComposeAssistantEntryStatus,
        errorMessage: String? = nil
    ) -> UUID {
        let id = UUID()
        interactions.insert(
            ComposeAssistantEntry(
                id: id,
                kind: kind,
                prompt: prompt,
                response: response,
                command: command,
                contextSnippet: contextSnippet,
                status: status,
                errorMessage: errorMessage,
                createdAt: Date()
            ),
            at: 0
        )
        if interactions.count > Self.maxEntries {
            interactions = Array(interactions.prefix(Self.maxEntries))
        }
        return id
    }

    @discardableResult
    func beginEntry(
        kind: ComposeAssistantEntryKind,
        prompt: String,
        command: String? = nil,
        contextSnippet: String? = nil
    ) -> UUID {
        addEntry(
            kind: kind,
            prompt: prompt,
            response: "",
            command: command,
            contextSnippet: contextSnippet,
            status: .pending
        )
    }

    func finishEntry(id: UUID, response: String, command: String? = nil, contextSnippet: String? = nil) {
        updateEntry(id: id) { entry in
            entry.response = response
            entry.command = command ?? entry.command
            if let contextSnippet, !contextSnippet.isEmpty {
                entry.contextSnippet = contextSnippet
            }
            entry.errorMessage = nil
            entry.status = .ready
        }
    }

    func updatePendingEntry(
        id: UUID,
        response: String,
        command: String? = nil,
        contextSnippet: String? = nil
    ) {
        updateEntry(id: id) { entry in
            entry.response = response
            if let command {
                entry.command = command
            }
            if let contextSnippet, !contextSnippet.isEmpty {
                entry.contextSnippet = contextSnippet
            }
            entry.errorMessage = nil
            entry.status = .pending
        }
    }

    func failEntry(id: UUID, message: String, contextSnippet: String? = nil) {
        updateEntry(id: id) { entry in
            entry.errorMessage = message
            if let contextSnippet, !contextSnippet.isEmpty {
                entry.contextSnippet = contextSnippet
            }
            entry.status = .failed
        }
    }

    func markInserted(id: UUID) {
        updateEntry(id: id) { entry in
            entry.status = .inserted
        }
    }

    func markRan(id: UUID) {
        updateEntry(id: id) { entry in
            entry.status = .ran
        }
    }

    func loadDraft(from id: UUID) -> Bool {
        guard let entry = entry(id: id), let command = entry.runnableCommand else { return false }
        loadedSuggestionContext = LoadedSuggestionContext(
            entryID: id,
            previousDraft: draftText,
            previousMode: mode,
            previousModeLocked: isModeLocked
        )
        draftText = command
        mode = .shell
        onDraftTextChanged?(command)
        markInserted(id: id)
        return true
    }

    func revertLoadedSuggestion() {
        guard let loadedSuggestionContext else { return }
        draftText = loadedSuggestionContext.previousDraft
        mode = loadedSuggestionContext.previousMode
        isModeLocked = loadedSuggestionContext.previousModeLocked
        onDraftTextChanged?(loadedSuggestionContext.previousDraft)
        clearLoadedSuggestionContext()
    }

    func clearLoadedSuggestionContext() {
        loadedSuggestionContext = nil
    }

    func attachContext(_ snippet: String, to id: UUID) {
        let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateEntry(id: id) { entry in
            entry.contextSnippet = trimmed
        }
    }

    func entry(id: UUID) -> ComposeAssistantEntry? {
        interactions.first(where: { $0.id == id })
    }

    func clearHistory() {
        interactions.removeAll()
    }

    private func updateEntry(id: UUID, update: (inout ComposeAssistantEntry) -> Void) {
        guard let index = interactions.firstIndex(where: { $0.id == id }) else { return }
        var updatedInteractions = interactions
        var entry = updatedInteractions[index]
        update(&entry)
        updatedInteractions[index] = entry
        interactions = updatedInteractions
    }
}

enum OllamaCommandServiceError: LocalizedError {
    case invalidEndpoint(String)
    case invalidResponse
    case httpError(Int, String)
    case requestTimedOut(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let endpoint):
            return "Invalid Ollama endpoint: \(endpoint)"
        case .invalidResponse:
            return "Ollama returned an invalid response."
        case .httpError(let status, let body):
            return body.isEmpty ? "Ollama request failed with HTTP \(status)." : "Ollama request failed with HTTP \(status): \(body)"
        case .requestTimedOut(let endpoint):
            return "Ollama timed out at \(endpoint). Check the endpoint, model, or server load."
        case .transport(let message):
            return message
        }
    }
}

private struct OllamaGenerateRequest: Encodable {
    let model: String
    let prompt: String
    let stream: Bool
    let options: OllamaOptions
}

private struct OllamaOptions: Encodable {
    let temperature: Double
}

private struct OllamaGenerateResponse: Decodable {
    let response: String
}

private struct OllamaGenerateStreamResponse: Decodable {
    let response: String?
    let done: Bool?
    let error: String?
}

enum OllamaAgentDecisionAction: String, Sendable {
    case run
    case done
    case browse
}

struct BrowseAction: Sendable {
    let url: String
    let tool: String       // "browser_snapshot", "browser_get_text", etc.
    let selector: String?
}

struct OllamaAgentDecision: Sendable {
    let action: OllamaAgentDecisionAction
    let command: String?
    let message: String
    let rawResponse: String
    let browseAction: BrowseAction?

    init(action: OllamaAgentDecisionAction, command: String?, message: String, rawResponse: String, browseAction: BrowseAction? = nil) {
        self.action = action
        self.command = command
        self.message = message
        self.rawResponse = rawResponse
        self.browseAction = browseAction
    }
}

private struct OllamaTagsResponse: Decodable {
    let models: [OllamaTag]
}

private struct OllamaTag: Decodable {
    let name: String
}

enum OllamaCommandService {
    static let defaultEndpoint = "http://127.0.0.1:11434"
    static let defaultModel = "qwen2.5-coder:7b"
    private static let requestTimeout: TimeInterval = 45

    static func currentEndpoint() -> String {
        let value = UserDefaults.standard.string(forKey: AppStorageKeys.ollamaEndpoint)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value! : defaultEndpoint
    }

    static func currentModel() -> String {
        let value = UserDefaults.standard.string(forKey: AppStorageKeys.ollamaModel)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty == false) ? value! : defaultModel
    }

    static func currentLaunchCommand() -> String {
        launchCommand(endpoint: currentEndpoint(), model: currentModel())
    }

    static func testConnection(endpoint: String, model: String) async throws -> String {
        let resolvedEndpoint = resolveEndpoint(endpoint)
        let resolvedModel = resolveModel(model)

        guard var url = URL(string: resolvedEndpoint) else {
            throw OllamaCommandServiceError.invalidEndpoint(resolvedEndpoint)
        }
        url.append(path: "api/tags")

        var httpRequest = URLRequest(url: url)
        httpRequest.httpMethod = "GET"
        httpRequest.timeoutInterval = requestTimeout

        let (data, _) = try await performRequest(httpRequest, endpoint: resolvedEndpoint)
        let tags = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
        let availableModels = tags.models.map(\.name)

        if availableModels.contains(resolvedModel) {
            return "Connected to \(resolvedEndpoint). Model \(resolvedModel) is available."
        }

        if availableModels.isEmpty {
            return "Connected to \(resolvedEndpoint), but the server did not report any installed models."
        }

        let preview = availableModels.prefix(8).joined(separator: ", ")
        return "Connected to \(resolvedEndpoint), but model \(resolvedModel) was not found. Available models: \(preview)"
    }

    static func launchCommand(endpoint: String, model: String) -> String {
        let resolvedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultEndpoint
            : endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModel = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultModel
            : model.trimmingCharacters(in: .whitespacesAndNewlines)

        if resolvedEndpoint == defaultEndpoint {
            return "ollama run \(shellQuote(resolvedModel))"
        }

        return "OLLAMA_HOST=\(shellQuote(resolvedEndpoint)) ollama run \(shellQuote(resolvedModel))"
    }

    static func generateCommand(
        for request: String,
        pwd: String?,
        terminalObservation: String? = nil
    ) async throws -> String {
        let context = await TerminalContextGatherer.gather(pwd: pwd)
        let prompt = buildCommandPrompt(
            request: request,
            context: context,
            terminalObservation: terminalObservation
        )
        return try await sendPrompt(prompt, temperature: 0.15)
    }

    static func streamCommand(
        for request: String,
        pwd: String?,
        terminalObservation: String? = nil,
        onPartial: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        let context = await TerminalContextGatherer.gather(pwd: pwd)
        let prompt = buildCommandPrompt(
            request: request,
            context: context,
            terminalObservation: terminalObservation
        )
        return try await streamPrompt(prompt, temperature: 0.15, onPartial: onPartial)
    }

    static func explainCommandOutput(command: String?, output: String, pwd: String?) async throws -> String {
        let context = await TerminalContextGatherer.gather(pwd: pwd)
        let prompt = buildExplainPrompt(command: command, output: output, context: context)
        return try await sendPrompt(prompt, temperature: 0.2)
    }

    static func streamExplainCommandOutput(
        command: String?,
        output: String,
        pwd: String?,
        onPartial: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        let context = await TerminalContextGatherer.gather(pwd: pwd)
        let prompt = buildExplainPrompt(command: command, output: output, context: context)
        return try await streamPrompt(prompt, temperature: 0.2, onPartial: onPartial)
    }

    static func suggestFix(command: String?, output: String, pwd: String?) async throws -> String {
        let context = await TerminalContextGatherer.gather(pwd: pwd)
        let prompt = buildFixPrompt(command: command, output: output, context: context)
        return try await sendPrompt(prompt, temperature: 0.15)
    }

    static func streamSuggestFix(
        command: String?,
        output: String,
        pwd: String?,
        onPartial: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        let context = await TerminalContextGatherer.gather(pwd: pwd)
        let prompt = buildFixPrompt(command: command, output: output, context: context)
        return try await streamPrompt(prompt, temperature: 0.15, onPartial: onPartial)
    }

    // MARK: - Multi-Step Plan Generation

    /// Generates a structured multi-step plan for a goal. Returns parsed steps.
    /// Streams partial text to `onPartial` for shimmer/preview display.
    static func streamAgentPlan(
        goal: String,
        backend: AgentPlanningBackend = .ollama,
        scope: GoalScope? = nil,
        pwd: String?,
        recentCommandContext: String,
        onPartial: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> [AgentPlanStep] {
        let resolvedScope = scope ?? IntentRouter.inferScope(goal)
        let context = await TerminalContextGatherer.gather(pwd: pwd, scope: resolvedScope)
        let prompt = buildPlanPrompt(
            goal: goal,
            context: context,
            scope: resolvedScope,
            recentCommandContext: recentCommandContext
        )

        let raw: String
        if backend == .claudeSubscription {
            await onPartial("Generating plan with Claude…")
            raw = try await runClaudePrompt(prompt, cwd: pwd)
        } else {
            raw = try await streamPrompt(prompt, temperature: 0.15, onPartial: onPartial)
        }

        return parsePlanSteps(raw)
    }

    private static func buildPlanPrompt(
        goal: String,
        context: TerminalContext,
        scope: GoalScope,
        recentCommandContext: String
    ) -> String {
        """
        You are CTerm Agent, a terminal agent embedded in a macOS terminal app.

        Create a step-by-step plan to achieve the user's goal using shell commands.

        Rules:
        - Output 2-8 steps, each on its own line.
        - Use exactly this format for each step:
          STEP: <short description of what this step does>
          COMMAND: <the shell command to run>
        - If a step doesn't need a command (e.g. "verify the output"), omit the COMMAND line.
        - Keep descriptions under 15 words.
        - Prefer one command per step.
        - Respect the goal scope.
        - Do not default to git, repo, or project commands unless the scope is project or the user explicitly asked for them.
        - Do not use markdown fences.
        - Order steps logically.
        - If the goal is trivial (one command), output a single step.

        Context:
        \(context.contextBlock)
        - Scope guidance: \(scope.label)
        - Goal: \(goal)

        Recent command history:
        \(recentCommandContext.isEmpty ? "(none)" : recentCommandContext)
        """
    }

    private static func parsePlanSteps(_ raw: String) -> [AgentPlanStep] {
        let cleaned = cleanResponse(raw)
        let lines = cleaned.components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var steps: [AgentPlanStep] = []
        var currentTitle: String?
        var currentCommand: String?

        for line in lines {
            let upper = line.uppercased()
            if upper.hasPrefix("STEP:") {
                // Flush previous step
                if let title = currentTitle {
                    steps.append(AgentPlanStep(title: title, command: currentCommand))
                }
                currentTitle = line
                    .split(separator: ":", maxSplits: 1)
                    .dropFirst().first
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                currentCommand = nil
            } else if upper.hasPrefix("COMMAND:") {
                currentCommand = line
                    .split(separator: ":", maxSplits: 1)
                    .dropFirst().first
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            }
        }
        // Flush last step
        if let title = currentTitle {
            steps.append(AgentPlanStep(title: title, command: currentCommand))
        }

        // Fallback: if parsing found nothing, try to extract a single command
        if steps.isEmpty {
            let decision = try? parseAgentDecision(raw)
            if let decision, decision.action == .run, let cmd = decision.command {
                steps.append(AgentPlanStep(title: decision.message, command: cmd))
            } else if let decision, decision.action == .done {
                steps.append(AgentPlanStep(title: decision.message))
            }
        }

        return steps
    }

    static func streamAgentDecision(
        goal: String,
        backend: AgentPlanningBackend = .ollama,
        scope: GoalScope? = nil,
        pwd: String?,
        recentCommandContext: String,
        priorAgentContext: String,
        onPartial: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> OllamaAgentDecision {
        let resolvedScope = scope ?? IntentRouter.inferScope(goal)
        if backend == .claudeSubscription {
            return try await streamClaudeAgentDecision(
                goal: goal,
                scope: resolvedScope,
                pwd: pwd,
                recentCommandContext: recentCommandContext,
                priorAgentContext: priorAgentContext,
                onPartial: onPartial
            )
        }

        let context = await TerminalContextGatherer.gather(pwd: pwd, scope: resolvedScope)
        let prompt = buildAgentPrompt(
            goal: goal,
            context: context,
            scope: resolvedScope,
            recentCommandContext: recentCommandContext,
            priorAgentContext: priorAgentContext
        )
        let raw = try await streamPrompt(prompt, temperature: 0.2, onPartial: onPartial)
        return try parseAgentDecision(raw)
    }

    private static func streamClaudeAgentDecision(
        goal: String,
        scope: GoalScope,
        pwd: String?,
        recentCommandContext: String,
        priorAgentContext: String,
        onPartial: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> OllamaAgentDecision {
        let context = await TerminalContextGatherer.gather(pwd: pwd, scope: scope)
        let prompt = buildClaudeAgentPrompt(
            goal: goal,
            context: context,
            scope: scope,
            recentCommandContext: recentCommandContext,
            priorAgentContext: priorAgentContext
        )
        await onPartial("Planning the next terminal step with Claude Subscription…")
        let raw = try await runClaudePrompt(prompt, cwd: pwd)
        return try parseAgentDecision(raw)
    }

    private static func sendPrompt(_ prompt: String, temperature: Double) async throws -> String {
        let endpoint = currentEndpoint()
        guard var url = URL(string: endpoint) else {
            throw OllamaCommandServiceError.invalidEndpoint(endpoint)
        }
        url.append(path: "api/generate")

        var httpRequest = URLRequest(url: url)
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        httpRequest.timeoutInterval = requestTimeout

        let body = OllamaGenerateRequest(
            model: currentModel(),
            prompt: prompt,
            stream: false,
            options: OllamaOptions(temperature: temperature)
        )
        httpRequest.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await performRequest(httpRequest, endpoint: endpoint)
        guard response is HTTPURLResponse else {
            throw OllamaCommandServiceError.invalidResponse
        }

        let decoded = try JSONDecoder().decode(OllamaGenerateResponse.self, from: data)
        let cleaned = cleanResponse(decoded.response)
        guard !cleaned.isEmpty else {
            throw OllamaCommandServiceError.invalidResponse
        }
        return cleaned
    }

    private static func runClaudePrompt(_ prompt: String, cwd: String?) async throws -> String {
        do {
            let output = try await ClaudeCLIService.runPrintPrompt(
                prompt,
                cwd: cwd,
                timeout: requestTimeout
            )
            return cleanResponse(output)
        } catch let error as ClaudeCLIServiceError {
            throw OllamaCommandServiceError.transport(error.localizedDescription)
        } catch {
            throw OllamaCommandServiceError.transport(error.localizedDescription)
        }
    }

    private static func streamPrompt(
        _ prompt: String,
        temperature: Double,
        onPartial: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        let endpoint = currentEndpoint()
        guard var url = URL(string: endpoint) else {
            throw OllamaCommandServiceError.invalidEndpoint(endpoint)
        }
        url.append(path: "api/generate")

        var httpRequest = URLRequest(url: url)
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        httpRequest.timeoutInterval = requestTimeout

        let body = OllamaGenerateRequest(
            model: currentModel(),
            prompt: prompt,
            stream: true,
            options: OllamaOptions(temperature: temperature)
        )
        httpRequest.httpBody = try JSONEncoder().encode(body)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        let session = URLSession(configuration: configuration)

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: httpRequest)
        } catch let error as URLError where error.code == .timedOut {
            throw OllamaCommandServiceError.requestTimedOut(endpoint)
        } catch let error as URLError where error.code == .cannotConnectToHost || error.code == .cannotFindHost || error.code == .networkConnectionLost || error.code == .notConnectedToInternet {
            throw OllamaCommandServiceError.transport("Could not reach Ollama at \(endpoint): \(error.localizedDescription)")
        } catch {
            throw OllamaCommandServiceError.transport("Ollama request failed: \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw OllamaCommandServiceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OllamaCommandServiceError.httpError(http.statusCode, "")
        }

        var accumulated = ""
        for try await line in bytes.lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedLine.isEmpty else { continue }

            let chunkData = Data(trimmedLine.utf8)
            let chunk = try JSONDecoder().decode(OllamaGenerateStreamResponse.self, from: chunkData)
            if let error = chunk.error, !error.isEmpty {
                throw OllamaCommandServiceError.transport(error)
            }
            if let responseChunk = chunk.response, !responseChunk.isEmpty {
                accumulated += responseChunk
                let cleanedPartial = cleanResponse(accumulated)
                if !cleanedPartial.isEmpty {
                    await onPartial(cleanedPartial)
                }
            }
            if chunk.done == true {
                break
            }
        }

        let cleaned = cleanResponse(accumulated)
        guard !cleaned.isEmpty else {
            throw OllamaCommandServiceError.invalidResponse
        }
        return cleaned
    }

    private static func performRequest(
        _ httpRequest: URLRequest,
        endpoint: String
    ) async throws -> (Data, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout
        let session = URLSession(configuration: configuration)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: httpRequest)
        } catch let error as URLError where error.code == .timedOut {
            throw OllamaCommandServiceError.requestTimedOut(endpoint)
        } catch let error as URLError where error.code == .cannotConnectToHost || error.code == .cannotFindHost || error.code == .networkConnectionLost || error.code == .notConnectedToInternet {
            throw OllamaCommandServiceError.transport("Could not reach Ollama at \(endpoint): \(error.localizedDescription)")
        } catch {
            throw OllamaCommandServiceError.transport("Ollama request failed: \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw OllamaCommandServiceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw OllamaCommandServiceError.httpError(http.statusCode, bodyText)
        }
        return (data, response)
    }

    private static func buildCommandPrompt(
        request: String,
        context: TerminalContext,
        terminalObservation: String?
    ) -> String {
        return """
        You are Ollama running inside CTerm, a macOS terminal app.

        You are helping from CTerm's compose bar for the user's current terminal tab.
        In this mode, your reply is shown as a suggested command or a short NOTE.

        What CTerm gives you:
        - terminal metadata such as working directory, OS, shell, and repo context
        - optionally, a recent terminal error, command output snippet, or current viewport snippet from the same tab

        What the user can do with your reply in CTerm:
        - insert the suggested command into the compose bar
        - run the suggested command in the current terminal tab
        - ask follow-up explain or fix actions against recent terminal output

        Limits:
        - You do not execute commands yourself.
        - You only know terminal state that CTerm includes in this prompt.
        - If terminal observation is present below, treat it as live context from the current tab and use it directly.

        Return the single best shell command for the user's request.

        Rules:
        - Output only the command text when a command is appropriate.
        - Do not use markdown fences, bullets, or explanation.
        - Prefer one-liners.
        - Preserve safety. Do not propose destructive commands unless the user's intent clearly requires it.
        - If the user asks about terminal output and a terminal observation is included, use that observation instead of saying you cannot inspect terminal output.
        - If a command would be unsafe, ambiguous, or the request is not really a shell command task, respond with a brief plain-English sentence prefixed by NOTE:

        Context:
        \(context.contextBlock)

        Current terminal observation:
        \(terminalObservationBlock(terminalObservation))

        User request:
        \(request)
        """
    }

    private static func buildExplainPrompt(command: String?, output: String, context: TerminalContext) -> String {
        let commandText = command?.isEmpty == false ? command! : "(unknown command)"
        return """
        You are Ollama running inside CTerm, a macOS terminal app.

        The output below was captured from the user's current terminal tab.

        Explain what happened in the terminal output below.

        Rules:
        - Respond in plain English.
        - Be concise and concrete.
        - Mention the most likely cause first.
        - End with the next thing the user should try.
        - Do not use markdown fences.

        Context:
        \(context.contextBlock)
        - Command: \(commandText)

        Terminal output:
        \(trimmedContext(output))
        """
    }

    private static func buildFixPrompt(command: String?, output: String, context: TerminalContext) -> String {
        let commandText = command?.isEmpty == false ? command! : "(unknown command)"
        return """
        You are Ollama running inside CTerm, a macOS terminal app.

        The output below was captured from the user's current terminal tab.

        The command below failed. Return the single best replacement shell command.

        Rules:
        - Output only the replacement command text when a command is appropriate.
        - Do not use markdown fences or explanation.
        - Prefer one-liners.
        - Keep the fix as close as possible to the original intent.
        - If the output is ambiguous or a command would be unsafe, respond with a brief plain-English sentence prefixed by NOTE:

        Context:
        \(context.contextBlock)
        - Original command: \(commandText)

        Failure output:
        \(trimmedContext(output))
        """
    }

    private static func buildAgentPrompt(
        goal: String,
        context: TerminalContext,
        scope: GoalScope,
        recentCommandContext: String,
        priorAgentContext: String
    ) -> String {
        let diagnosticGuidance = buildDiagnosticGuidance(goal: goal, scope: scope)
        return """
        You are CTerm Agent, a local terminal agent embedded in a macOS terminal app.

        Decide the next terminal action for the user's goal.

        Rules:
        - Prefer one shell command per step.
        - Only propose commands that are necessary for progress.
        - Respect the goal scope.
        - Do not default to git, repo, or project commands unless the scope is project or the user explicitly asked for them.
        - Do not propose destructive commands unless the goal clearly requires them.
        - If the goal is complete, respond with ACTION: DONE.
        - If a command is needed, respond with ACTION: RUN.
        - Use exactly this format:
          ACTION: RUN
          COMMAND: <single shell command>
          MESSAGE: <one concise sentence about why this is the next step>

          or:
          ACTION: DONE
          MESSAGE: <one concise sentence summarizing the result or next manual step>
        - Do not use markdown fences or bullet lists.
        \(diagnosticGuidance)

        Context:
        \(context.contextBlock)
        - Scope guidance: \(scope.label)
        - Goal: \(goal)

        Recent command history:
        \(recentCommandContext.isEmpty ? "(none)" : recentCommandContext)

        Previous agent state:
        \(priorAgentContext.isEmpty ? "(none)" : priorAgentContext)
        """
    }

    private static func buildClaudeAgentPrompt(
        goal: String,
        context: TerminalContext,
        scope: GoalScope,
        recentCommandContext: String,
        priorAgentContext: String
    ) -> String {
        let diagnosticGuidance = buildDiagnosticGuidance(goal: goal, scope: scope)
        return """
        You are CTerm Agent, a terminal agent embedded in a macOS terminal app and powered by Claude Subscription.

        Decide the next terminal action for the user's goal.

        Rules:
        - Prefer one shell command per step.
        - Only propose commands that are necessary for progress.
        - Respect the goal scope.
        - Do not default to git, repo, or project commands unless the scope is project or the user explicitly asked for them.
        - Do not propose destructive commands unless the goal clearly requires them.
        - If the goal is complete, respond with ACTION: DONE.
        - If a command is needed, respond with ACTION: RUN.
        - Use exactly this format:
          ACTION: RUN
          COMMAND: <single shell command>
          MESSAGE: <one concise sentence about why this is the next step>

          or:
          ACTION: DONE
          MESSAGE: <one concise sentence summarizing the result or next manual step>
        - Do not use markdown fences or bullet lists.
        \(diagnosticGuidance)

        Context:
        \(context.contextBlock)
        - Scope guidance: \(scope.label)
        - Goal: \(goal)

        Recent command history:
        \(recentCommandContext.isEmpty ? "(none)" : recentCommandContext)

        Previous agent state:
        \(priorAgentContext.isEmpty ? "(none)" : priorAgentContext)
        """
    }

    private static func trimmedContext(_ text: String, limit: Int = 3_000) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        let start = trimmed.index(trimmed.endIndex, offsetBy: -limit)
        return String(trimmed[start...])
    }

    private static func buildDiagnosticGuidance(goal: String, scope: GoalScope) -> String {
        guard InlineAgentCompletionHeuristics.requiresInterpretation(intent: goal, scope: scope) else {
            return "- If the goal is clearly satisfied after one command, you may respond with ACTION: DONE."
        }

        return """
        - This is a diagnostic or troubleshooting goal. Do not stop after one observational command unless the output already supports a concrete conclusion.
        - When you respond with ACTION: DONE, MESSAGE must explain the conclusion in plain English instead of merely restating command output.
        """
    }

    private static func terminalObservationBlock(_ terminalObservation: String?) -> String {
        guard let terminalObservation else { return "(none provided)" }
        let trimmed = terminalObservation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "(none provided)" }
        return trimmedContext(trimmed, limit: 2_000)
    }

    private static func cleanResponse(_ response: String) -> String {
        var text = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text
                .replacingOccurrences(of: "```bash", with: "")
                .replacingOccurrences(of: "```sh", with: "")
                .replacingOccurrences(of: "```shell", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private static func parseAgentDecision(_ raw: String) throws -> OllamaAgentDecision {
        let cleaned = cleanResponse(raw)
        let lines = cleaned
            .components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let actionLine = lines.first { $0.uppercased().hasPrefix("ACTION:") }
        let commandLine = lines.first { $0.uppercased().hasPrefix("COMMAND:") }
        let messageLine = lines.first { $0.uppercased().hasPrefix("MESSAGE:") }

        let actionValue = actionLine?
            .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .dropFirst()
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let messageValue = messageLine?
            .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .dropFirst()
            .first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

        switch actionValue {
        case "run":
            let commandValue = commandLine?
                .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                .dropFirst()
                .first
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            guard let commandValue, !commandValue.isEmpty else {
                throw OllamaCommandServiceError.invalidResponse
            }
            return OllamaAgentDecision(
                action: .run,
                command: commandValue,
                message: messageValue?.isEmpty == false ? messageValue! : "Run the next terminal step.",
                rawResponse: cleaned
            )
        case "done":
            return OllamaAgentDecision(
                action: .done,
                command: nil,
                message: messageValue?.isEmpty == false ? messageValue! : cleaned,
                rawResponse: cleaned
            )
        default:
            if cleaned.hasPrefix("NOTE:") {
                return OllamaAgentDecision(
                    action: .done,
                    command: nil,
                    message: cleaned,
                    rawResponse: cleaned
                )
            }

            if let fallbackCommand = extractFallbackAgentCommand(from: cleaned, lines: lines) {
                return OllamaAgentDecision(
                    action: .run,
                    command: fallbackCommand,
                    message: fallbackAgentMessage(from: cleaned),
                    rawResponse: cleaned
                )
            }

            if looksLikeCompletionSummary(cleaned) {
                return OllamaAgentDecision(
                    action: .done,
                    command: nil,
                    message: cleaned,
                    rawResponse: cleaned
                )
            }

            throw OllamaCommandServiceError.invalidResponse
        }
    }

    private static func extractFallbackAgentCommand(from cleaned: String, lines: [String]) -> String? {
        if let explicit = lines.first(where: {
            let upper = $0.uppercased()
            return upper.hasPrefix("COMMAND:")
                || upper.hasPrefix("RUN:")
                || upper.hasPrefix("NEXT COMMAND:")
        }) {
            let value = explicit
                .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                .dropFirst()
                .first
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            if let value, looksLikeShellCommand(value) {
                return value
            }
        }

        let fencedBlocks = cleaned.components(separatedBy: "```")
        if fencedBlocks.count >= 2 {
            for block in fencedBlocks {
                let trimmed = block
                    .replacingOccurrences(of: "bash", with: "")
                    .replacingOccurrences(of: "sh", with: "")
                    .replacingOccurrences(of: "shell", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if looksLikeShellCommand(trimmed) {
                    return trimmed
                }
            }
        }

        for line in lines {
            let normalized = line
                .trimmingCharacters(in: CharacterSet(charactersIn: "-*•1234567890. "))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if looksLikeShellCommand(normalized) {
                return normalized
            }
        }

        if looksLikeShellCommand(cleaned) {
            return cleaned
        }

        return nil
    }

    private static func fallbackAgentMessage(from cleaned: String) -> String {
        let lines = cleaned
            .components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let messageLine = lines.first(where: {
            let upper = $0.uppercased()
            return upper.hasPrefix("MESSAGE:")
                || upper.hasPrefix("PLAN:")
                || upper.hasPrefix("WHY:")
        })

        if let messageLine {
            return messageLine
                .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                .dropFirst()
                .first
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                ?? "Run the next terminal step."
        }

        return "Run the next terminal step."
    }

    private static func looksLikeCompletionSummary(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.hasPrefix("done")
            || lowered.hasPrefix("complete")
            || lowered.hasPrefix("completed")
            || lowered.contains("goal is complete")
            || lowered.contains("task is complete")
            || lowered.contains("no further command")
    }

    private static func looksLikeShellCommand(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !trimmed.contains("ACTION:"),
              !trimmed.contains("MESSAGE:")
        else { return false }

        if trimmed.contains("\n") {
            let lines = trimmed
                .components(separatedBy: CharacterSet.newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard lines.count <= 4 else { return false }
            return lines.allSatisfy { looksLikeShellCommand($0) }
        }

        let firstToken = trimmed.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        let commonCommands: Set<String> = [
            "ls", "cd", "pwd", "cat", "rg", "grep", "find", "git", "swift", "xcodebuild",
            "make", "npm", "pnpm", "yarn", "bun", "cargo", "go", "python", "python3",
            "pip", "pip3", "docker", "kubectl", "curl", "wget", "sed", "awk", "jq",
            "chmod", "chown", "mv", "cp", "ln", "mkdir", "rm", "touch", "open", "defaults",
            "plutil", "osascript"
        ]

        if commonCommands.contains(firstToken) {
            return true
        }

        if trimmed.contains("/") || trimmed.contains("|") || trimmed.contains("&&")
            || trimmed.contains("$(") || trimmed.contains("--") || trimmed.contains(">")
            || trimmed.contains("*") || trimmed.contains("=") {
            return true
        }

        if firstToken.range(of: #"^[A-Za-z0-9._/-]+$"#, options: .regularExpression) != nil,
           trimmed.range(of: #"^[A-Za-z0-9._/-]+(\s+[A-Za-z0-9_./:=@%+-]+)+$"#, options: .regularExpression) != nil {
            return true
        }

        return false
    }

    private static func resolveEndpoint(_ endpoint: String) -> String {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultEndpoint : trimmed
    }

    private static func resolveModel(_ model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultModel : trimmed
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
