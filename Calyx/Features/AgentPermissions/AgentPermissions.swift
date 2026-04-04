// AgentPermissions.swift
// Calyx
//
// Warp-style per-action autonomy levels for agent tool execution.
// Persisted to UserDefaults. Read by ComposeOverlayController and AutoAcceptMonitor.

import Foundation
import Observation

// MARK: - Autonomy Level

enum AgentAutonomyLevel: String, Codable, CaseIterable, Sendable {
    /// Agent decides when to ask — runs safe ops silently, asks for risky ones.
    case agentDecides = "agentDecides"
    /// Always prompt the user before executing this action type.
    case alwaysAsk = "alwaysAsk"
    /// Always execute without prompting.
    case alwaysAllow = "alwaysAllow"
    /// Never allow this action type.
    case never = "never"

    var displayName: String {
        switch self {
        case .agentDecides: return "Let agent decide"
        case .alwaysAsk:    return "Always ask"
        case .alwaysAllow:  return "Always allow"
        case .never:        return "Never"
        }
    }

    var icon: String {
        switch self {
        case .agentDecides: return "cpu"
        case .alwaysAsk:    return "questionmark.circle"
        case .alwaysAllow:  return "checkmark.circle.fill"
        case .never:        return "xmark.circle.fill"
        }
    }

    var tintName: String {
        switch self {
        case .agentDecides: return "blue"
        case .alwaysAsk:    return "orange"
        case .alwaysAllow:  return "green"
        case .never:        return "red"
        }
    }
}

// MARK: - Action Category

enum AgentActionCategory: String, Codable, CaseIterable, Sendable {
    case readFiles      = "readFiles"
    case writeFiles     = "writeFiles"
    case runCommands    = "runCommands"
    case networkAccess  = "networkAccess"
    case gitOperations  = "gitOperations"
    case deleteFiles    = "deleteFiles"

    var displayName: String {
        switch self {
        case .readFiles:     return "Read files"
        case .writeFiles:    return "Write / edit files"
        case .runCommands:   return "Run shell commands"
        case .networkAccess: return "Network access"
        case .gitOperations: return "Git operations"
        case .deleteFiles:   return "Delete files"
        }
    }

    var description: String {
        switch self {
        case .readFiles:     return "cat, ls, grep, find, head, tail, etc."
        case .writeFiles:    return "Write, create, or modify source files"
        case .runCommands:   return "Execute arbitrary shell commands"
        case .networkAccess: return "curl, wget, npm install, etc."
        case .gitOperations: return "git commit, push, branch, merge, etc."
        case .deleteFiles:   return "rm, rmdir, trash, etc."
        }
    }

    var icon: String {
        switch self {
        case .readFiles:     return "doc.text"
        case .writeFiles:    return "pencil"
        case .runCommands:   return "terminal"
        case .networkAccess: return "network"
        case .gitOperations: return "arrow.triangle.branch"
        case .deleteFiles:   return "trash"
        }
    }

    /// Default autonomy level for this category.
    var defaultLevel: AgentAutonomyLevel {
        switch self {
        case .readFiles:     return .alwaysAllow
        case .writeFiles:    return .agentDecides
        case .runCommands:   return .agentDecides
        case .networkAccess: return .alwaysAsk
        case .gitOperations: return .alwaysAsk
        case .deleteFiles:   return .alwaysAsk
        }
    }
}

// MARK: - Profile

struct AgentPermissionProfile: Codable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var levels: [String: AgentAutonomyLevel]  // keyed by AgentActionCategory.rawValue

    init(name: String, levels: [AgentActionCategory: AgentAutonomyLevel] = [:]) {
        self.id = UUID()
        self.name = name
        var dict: [String: AgentAutonomyLevel] = [:]
        for cat in AgentActionCategory.allCases {
            dict[cat.rawValue] = levels[cat] ?? cat.defaultLevel
        }
        self.levels = dict
    }

    func level(for category: AgentActionCategory) -> AgentAutonomyLevel {
        levels[category.rawValue] ?? category.defaultLevel
    }

    mutating func setLevel(_ level: AgentAutonomyLevel, for category: AgentActionCategory) {
        levels[category.rawValue] = level
    }

    // MARK: - Built-in profiles

    static let balanced = AgentPermissionProfile(name: "Balanced", levels: [:])

    static let yolo = AgentPermissionProfile(name: "YOLO", levels: [
        .readFiles:     .alwaysAllow,
        .writeFiles:    .alwaysAllow,
        .runCommands:   .alwaysAllow,
        .networkAccess: .alwaysAllow,
        .gitOperations: .alwaysAllow,
        .deleteFiles:   .alwaysAsk,
    ])

    static let cautious = AgentPermissionProfile(name: "Cautious", levels: [
        .readFiles:     .alwaysAllow,
        .writeFiles:    .alwaysAsk,
        .runCommands:   .alwaysAsk,
        .networkAccess: .never,
        .gitOperations: .alwaysAsk,
        .deleteFiles:   .never,
    ])
}

// MARK: - Store

@Observable
@MainActor
final class AgentPermissionsStore {
    static let shared = AgentPermissionsStore()

    var profiles: [AgentPermissionProfile] = []
    var activeProfileID: UUID

    private let defaultsKey = "calyx.agentPermissions"
    private let activeProfileKey = "calyx.agentPermissions.activeProfile"

    private init() {
        let builtins: [AgentPermissionProfile] = [.balanced, .yolo, .cautious]
        self.profiles = builtins
        // Load active profile ID, default to balanced
        if let raw = UserDefaults.standard.string(forKey: activeProfileKey),
           let id = UUID(uuidString: raw) {
            self.activeProfileID = id
        } else {
            self.activeProfileID = builtins[0].id
        }
        loadCustomProfiles()
    }

    var activeProfile: AgentPermissionProfile {
        profiles.first(where: { $0.id == activeProfileID }) ?? .balanced
    }

    func level(for category: AgentActionCategory) -> AgentAutonomyLevel {
        activeProfile.level(for: category)
    }

    /// Returns true if the agent should proceed without asking for this category.
    func shouldAutoAllow(_ category: AgentActionCategory) -> Bool {
        switch level(for: category) {
        case .alwaysAllow: return true
        case .agentDecides: return true   // agent's own safe-command logic applies
        case .alwaysAsk, .never: return false
        }
    }

    /// Returns true if this action is blocked entirely.
    func isBlocked(_ category: AgentActionCategory) -> Bool {
        level(for: category) == .never
    }

    func setActiveProfile(_ id: UUID) {
        activeProfileID = id
        UserDefaults.standard.set(id.uuidString, forKey: activeProfileKey)
    }

    func addProfile(_ profile: AgentPermissionProfile) {
        profiles.append(profile)
        saveCustomProfiles()
    }

    func updateProfile(_ profile: AgentPermissionProfile) {
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[idx] = profile
        saveCustomProfiles()
    }

    func deleteProfile(id: UUID) {
        // Don't delete built-ins
        let builtinIDs = Set([AgentPermissionProfile.balanced.id, AgentPermissionProfile.yolo.id, AgentPermissionProfile.cautious.id])
        guard !builtinIDs.contains(id) else { return }
        profiles.removeAll { $0.id == id }
        if activeProfileID == id { activeProfileID = AgentPermissionProfile.balanced.id }
        saveCustomProfiles()
    }

    // MARK: - Persistence (custom profiles only)

    private func saveCustomProfiles() {
        let builtinIDs = Set([AgentPermissionProfile.balanced.id, AgentPermissionProfile.yolo.id, AgentPermissionProfile.cautious.id])
        let custom = profiles.filter { !builtinIDs.contains($0.id) }
        if let data = try? JSONEncoder().encode(custom) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private func loadCustomProfiles() {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let custom = try? JSONDecoder().decode([AgentPermissionProfile].self, from: data)
        else { return }
        profiles.append(contentsOf: custom)
    }
}
