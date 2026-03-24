// AutoAcceptMonitor.swift
// Calyx
//
// Polls a tab's terminal surfaces for Claude confirmation prompts and injects Enter to accept.

import Foundation
import GhosttyKit
import OSLog

private let logger = Logger(subsystem: "com.legato3.terminal", category: "AutoAcceptMonitor")

// Patterns that indicate Claude Code is waiting for confirmation.
// Deliberately specific to minimize false positives.
private let confirmationPatterns: [String] = [
    "Allow once",
    "Allow (a)",
    "Allow for this session",
    "Do you want to allow",
]

struct AutoAcceptEvent: Identifiable, Sendable {
    let id: UUID
    let tabID: UUID
    let tabTitle: String
    let snippet: String   // last matched line
    let timestamp: Date

    init(tabID: UUID, tabTitle: String, snippet: String) {
        self.id = UUID()
        self.tabID = tabID
        self.tabTitle = tabTitle
        self.snippet = snippet
        self.timestamp = Date()
    }
}

@MainActor
final class AutoAcceptMonitor {
    private weak var tab: Tab?
    private var pollTask: Task<Void, Never>?
    private var lastAcceptedAt: Date = .distantPast
    private static let cooldown: TimeInterval = 3.0
    private static let pollInterval: UInt64 = 400_000_000 // 400ms in ns

    init(tab: Tab) {
        self.tab = tab
    }

    func start() {
        guard pollTask == nil else { return }
        logger.info("AutoAccept started for tab \(self.tab?.id.uuidString ?? "?")")
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(nanoseconds: Self.pollInterval)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        logger.info("AutoAccept stopped for tab \(self.tab?.id.uuidString ?? "?")")
    }

    private func tick() {
        guard let tab else { stop(); return }
        guard tab.autoAcceptEnabled else { stop(); return }
        guard Date().timeIntervalSince(lastAcceptedAt) >= Self.cooldown else { return }

        // Check every surface in this tab
        for surfaceID in tab.registry.allIDs {
            guard let controller = tab.registry.controller(for: surfaceID) else { continue }
            guard let surface = controller.surface else { continue }

            guard let text = GhosttyFFI.surfaceReadViewportText(surface) else { continue }
            let lines = text.components(separatedBy: "\n")
            // Check last 12 lines
            let tail = lines.suffix(12).joined(separator: "\n")

            if let matched = matchedPattern(in: tail) {
                accept(surface: surface, tab: tab, snippet: matched)
                return  // only accept once per tick
            }
        }
    }

    private func matchedPattern(in text: String) -> String? {
        for pattern in confirmationPatterns {
            if text.contains(pattern) { return pattern }
        }
        return nil
    }

    private func accept(surface: ghostty_surface_t, tab: Tab, snippet: String) {
        lastAcceptedAt = Date()
        logger.info("AutoAccept: injecting Enter for \"\(snippet)\" in tab \"\(tab.title)\"")

        // Send Enter keypress (macOS keycode 0x24 = Return)
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = GHOSTTY_ACTION_PRESS
        keyEvent.keycode = 0x24
        keyEvent.mods = GHOSTTY_MODS_NONE
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.text = nil
        keyEvent.unshifted_codepoint = 0
        keyEvent.composing = false
        GhosttyFFI.surfaceKey(surface, event: keyEvent)
        keyEvent.action = GHOSTTY_ACTION_RELEASE
        GhosttyFFI.surfaceKey(surface, event: keyEvent)

        let event = AutoAcceptEvent(tabID: tab.id, tabTitle: tab.title, snippet: snippet)
        tab.autoAcceptLog.append(event)

        // Keep log bounded
        if tab.autoAcceptLog.count > 200 {
            tab.autoAcceptLog.removeFirst(tab.autoAcceptLog.count - 200)
        }
    }
}
