// TriggerEngine.swift
// Calyx
//
// Persistent "when X, do Y" automation rules. Rules are stored at
// ~/.calyx/triggers.json and evaluated whenever a trigger event fires.
//
// V1 triggers: commandFail, testFail, peerConnect
// V1 actions:  routeToClaude, notify, advanceQueue, remember

import Foundation
import UserNotifications
import OSLog
import Observation

private let logger = Logger(subsystem: "com.legato3.terminal", category: "TriggerEngine")

// MARK: - Model

enum TriggerType: String, Codable, CaseIterable, Sendable {
    case commandFail   = "commandFail"    // ShellErrorMonitor captured an error
    case testFail      = "testFail"       // Test runner finished with failures
    case peerConnect   = "peerConnect"    // An agent peer registered via IPC

    var displayName: String {
        switch self {
        case .commandFail:  return "Command fails"
        case .testFail:     return "Tests fail"
        case .peerConnect:  return "Agent connects"
        }
    }

    var icon: String {
        switch self {
        case .commandFail:  return "exclamationmark.triangle"
        case .testFail:     return "xmark.circle"
        case .peerConnect:  return "person.crop.circle.badge.plus"
        }
    }
}

enum ActionType: String, Codable, CaseIterable, Sendable {
    case routeToClaude = "routeToClaude"  // inject message into nearest Claude pane
    case notify        = "notify"         // desktop notification
    case advanceQueue  = "advanceQueue"   // advance the task queue
    case remember      = "remember"       // write to agent memory

    var displayName: String {
        switch self {
        case .routeToClaude:  return "Route to Claude"
        case .notify:         return "Desktop notification"
        case .advanceQueue:   return "Advance task queue"
        case .remember:       return "Remember a fact"
        }
    }

    var icon: String {
        switch self {
        case .routeToClaude:  return "arrow.up.forward.circle"
        case .notify:         return "bell"
        case .advanceQueue:   return "arrow.right.circle"
        case .remember:       return "brain.head.profile"
        }
    }
}

struct TriggerRule: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var enabled: Bool
    var triggerType: TriggerType
    var actionType: ActionType

    // Action parameters
    var actionMessage: String   // routeToClaude message (supports {snippet}, {test_names}, {peer_name})
    var notifyTitle: String     // notify title
    var notifyBody: String      // notify body
    var memoryKey: String       // remember key
    var memoryValue: String     // remember value

    init(
        name: String,
        triggerType: TriggerType,
        actionType: ActionType,
        actionMessage: String = "",
        notifyTitle: String = "",
        notifyBody: String = "",
        memoryKey: String = "",
        memoryValue: String = ""
    ) {
        self.id = UUID()
        self.name = name
        self.enabled = true
        self.triggerType = triggerType
        self.actionType = actionType
        self.actionMessage = actionMessage
        self.notifyTitle = notifyTitle
        self.notifyBody = notifyBody
        self.memoryKey = memoryKey
        self.memoryValue = memoryValue
    }

    var summary: String {
        "When \(triggerType.displayName.lowercased()) → \(actionType.displayName.lowercased())"
    }
}

// MARK: - Engine

@Observable
@MainActor
final class TriggerEngine {
    static let shared = TriggerEngine()

    var rules: [TriggerRule] = []

    private let storePath: URL
    private var observations: [NSObjectProtocol] = []

    private init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".calyx")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storePath = dir.appendingPathComponent("triggers.json")
        load()
    }

    // MARK: - Lifecycle

    func start() {
        guard observations.isEmpty else { return }
        let center = NotificationCenter.default

        observations = [
            center.addObserver(forName: .shellErrorCaptured, object: nil, queue: .main) { [weak self] note in
                let snippet = note.userInfo?["snippet"] as? String ?? ""
                let tab = note.userInfo?["tabTitle"] as? String ?? "unknown"
                Task { @MainActor [weak self] in
                    self?.fire(.commandFail, context: ["snippet": snippet, "tab": tab])
                }
            },
            center.addObserver(forName: .testRunnerFinished, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    let store = TestRunnerStore.shared
                    guard store.failCount > 0 else { return }
                    let names = store.failures.map(\.name).joined(separator: ", ")
                    self?.fire(.testFail, context: ["test_names": names, "fail_count": "\(store.failCount)"])
                }
            },
            center.addObserver(forName: .peerRegistered, object: nil, queue: .main) { [weak self] note in
                let name = note.userInfo?["name"] as? String ?? "agent"
                let role = note.userInfo?["role"] as? String ?? ""
                Task { @MainActor [weak self] in
                    self?.fire(.peerConnect, context: ["peer_name": name, "peer_role": role])
                }
            },
        ]
        logger.info("TriggerEngine started with \(self.rules.count) rules")
    }

    func stop() {
        observations.forEach { NotificationCenter.default.removeObserver($0) }
        observations = []
    }

    // MARK: - CRUD

    func add(_ rule: TriggerRule) {
        rules.append(rule)
        save()
    }

    func remove(id: UUID) {
        rules.removeAll { $0.id == id }
        save()
    }

    func toggle(id: UUID) {
        guard let idx = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[idx].enabled.toggle()
        save()
    }

    func update(_ rule: TriggerRule) {
        guard let idx = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[idx] = rule
        save()
    }

    // MARK: - Firing

    private func fire(_ trigger: TriggerType, context: [String: String]) {
        let matching = rules.filter { $0.enabled && $0.triggerType == trigger }
        guard !matching.isEmpty else { return }
        logger.info("TriggerEngine: firing \(trigger.rawValue) → \(matching.count) rule(s)")
        for rule in matching {
            execute(rule.actionType, rule: rule, context: context)
        }
    }

    private func execute(_ action: ActionType, rule: TriggerRule, context: [String: String]) {
        switch action {
        case .routeToClaude:
            let message = interpolate(rule.actionMessage.isEmpty ? defaultMessage(for: rule.triggerType, context: context) : rule.actionMessage, context: context)
            TerminalControlBridge.shared.routeToNearestClaudePaneOrActive(text: message)

        case .notify:
            let title = interpolate(rule.notifyTitle.isEmpty ? rule.name : rule.notifyTitle, context: context)
            let body  = interpolate(rule.notifyBody.isEmpty  ? defaultMessage(for: rule.triggerType, context: context) : rule.notifyBody, context: context)
            sendNotification(title: title, body: body)

        case .advanceQueue:
            TaskQueueStore.shared.advanceToNext()

        case .remember:
            guard !rule.memoryKey.isEmpty else { return }
            let value = interpolate(rule.memoryValue, context: context)
            let pwd = TerminalControlBridge.shared.delegate?.activeTabPwd ?? FileManager.default.currentDirectoryPath
            let projectKey = AgentMemoryStore.key(for: pwd)
            AgentMemoryStore.shared.remember(projectKey: projectKey, key: rule.memoryKey, value: value, ttlDays: nil)
            NotificationCenter.default.post(name: .agentMemoryChanged, object: nil)
        }
    }

    // MARK: - Helpers

    private func interpolate(_ template: String, context: [String: String]) -> String {
        var result = template
        for (key, value) in context {
            result = result.replacingOccurrences(of: "{\(key)}", with: value)
        }
        return result
    }

    private func defaultMessage(for trigger: TriggerType, context: [String: String]) -> String {
        switch trigger {
        case .commandFail:
            let snippet = context["snippet"] ?? ""
            let tab = context["tab"] ?? "unknown"
            return "A command failed in tab \"\(tab)\":\n\n\(snippet)\n\nPlease investigate and fix."
        case .testFail:
            let names = context["test_names"] ?? "unknown"
            let count = context["fail_count"] ?? "?"
            return "\(count) test(s) failed:\n\n\(names)\n\nPlease fix the failing tests."
        case .peerConnect:
            let name = context["peer_name"] ?? "agent"
            return "Agent \"\(name)\" connected. Ready to collaborate."
        }
    }

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { logger.warning("Notification failed: \(error)") }
        }
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        let tmp = storePath.appendingPathExtension("tmp")
        try? data.write(to: tmp, options: .atomic)
        _ = try? FileManager.default.replaceItemAt(storePath, withItemAt: tmp)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storePath),
              let decoded = try? JSONDecoder().decode([TriggerRule].self, from: data) else { return }
        rules = decoded
        logger.info("TriggerEngine loaded \(decoded.count) rules")
    }
}

// MARK: - Notification names

extension Notification.Name {
    static let shellErrorCaptured = Notification.Name("com.legato3.terminal.shellErrorCaptured")
    static let peerRegistered     = Notification.Name("com.legato3.terminal.peerRegistered")
}
