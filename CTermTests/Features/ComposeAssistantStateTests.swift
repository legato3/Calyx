import Foundation
import Testing
@testable import CTerm

@MainActor
@Suite("Compose Assistant State")
struct ComposeAssistantStateTests {
    private let keys = [
        AppStorageKeys.composeAssistantMode,
        AppStorageKeys.composeModeLocked,
        AppStorageKeys.composeLastAgentMode,
        AppStorageKeys.ollamaSuggestionBehavior,
        AppStorageKeys.hasSeenAgentAutoRouteHint,
    ]

    init() {
        resetDefaults()
    }

    @Test("Auto-detect keeps shell commands in shell and reuses the last agent backend for prompts")
    func effectiveModeUsesLastAgentBackend() {
        defer { resetDefaults() }

        let state = ComposeAssistantState()
        #expect(state.mode == .shell)
        #expect(state.isModeLocked == false)

        state.mode = .ollamaAgent
        #expect(state.lastAgentMode == .ollamaAgent)

        state.mode = .shell
        state.isModeLocked = false

        #expect(state.effectiveMode(for: "git status") == .shell)
        #expect(state.effectiveMode(for: "fix the failing tests") == .ollamaAgent)
    }

    @Test("Persisted local agent mode survives reload")
    func persistedLocalAgentModeSurvivesReload() {
        defer { resetDefaults() }

        let defaults = UserDefaults.standard
        defaults.set(ComposeAssistantMode.ollamaAgent.rawValue, forKey: AppStorageKeys.composeAssistantMode)
        defaults.set(ComposeAssistantMode.ollamaAgent.rawValue, forKey: AppStorageKeys.composeLastAgentMode)
        defaults.set(true, forKey: AppStorageKeys.composeModeLocked)

        let state = ComposeAssistantState()

        #expect(state.mode == .ollamaAgent)
        #expect(state.lastAgentMode == .ollamaAgent)
        #expect(state.isModeLocked)
    }

    @Test("Ollama suggestion mode does not replace the preferred agent backend")
    func ollamaCommandModeDoesNotReplacePreferredAgentBackend() {
        defer { resetDefaults() }

        let state = ComposeAssistantState()
        state.mode = .ollamaAgent
        #expect(state.lastAgentMode == .ollamaAgent)

        state.mode = .ollamaCommand

        #expect(state.lastAgentMode == .ollamaAgent)
    }

    @Test("Loading an Ollama suggestion primes shell mode for execution")
    func loadDraftSwitchesToShellAndMarksInserted() {
        defer { resetDefaults() }

        let state = ComposeAssistantState()
        state.mode = .ollamaCommand
        state.isModeLocked = true

        let entryID = state.addEntry(
            kind: .commandSuggestion,
            prompt: "show modified files",
            response: "git status --short",
            command: "git status --short",
            status: .ready
        )

        let loaded = state.loadDraft(from: entryID)

        #expect(loaded)
        #expect(state.draftText == "git status --short")
        #expect(state.mode == .shell)
        #expect(state.isModeLocked)
        #expect(state.entry(id: entryID)?.status == .inserted)
    }

    @Test("Reverting a loaded suggestion restores the original prompt and mode")
    func revertLoadedSuggestionRestoresPreviousDraft() {
        defer { resetDefaults() }

        let state = ComposeAssistantState()
        state.mode = .ollamaCommand
        state.isModeLocked = true
        state.setDraftText("find the changed files")

        let entryID = state.addEntry(
            kind: .commandSuggestion,
            prompt: "find the changed files",
            response: "git status --short",
            command: "git status --short",
            status: .ready
        )

        #expect(state.loadDraft(from: entryID))
        state.revertLoadedSuggestion()

        #expect(state.draftText == "find the changed files")
        #expect(state.mode == .ollamaCommand)
        #expect(state.isModeLocked)
        #expect(state.loadedSuggestionEntry == nil)
    }

    @Test("Ollama suggestion behavior defaults to autofill")
    func ollamaSuggestionBehaviorDefaultsToAutofill() {
        defer { resetDefaults() }

        #expect(OllamaSuggestionBehavior.current() == .autofill)
    }

    private func resetDefaults() {
        let defaults = UserDefaults.standard
        for key in keys {
            defaults.removeObject(forKey: key)
        }
    }
}
