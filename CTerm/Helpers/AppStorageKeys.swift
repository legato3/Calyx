// AppStorageKeys.swift
// CTerm
//
// Central registry of UserDefaults / AppStorage key strings.
// Use these constants instead of raw string literals to prevent silent key mismatches.

enum AppStorageKeys {
    static let terminalGlassOpacity = "terminalGlassOpacity"
    static let themeColorPreset = "themeColorPreset"
    static let themeColorCustomHex = "themeColorCustomHex"
    static let dailyCostBudgetEnabled = "dailyCostBudgetEnabled"
    static let dailyCostBudget = "dailyCostBudget"
    static let ghosttyTerminalOverrides = "ghosttyTerminalOverrides"
    static let ollamaEndpoint = "ollamaEndpoint"
    static let ollamaModel = "ollamaModel"
    static let claudeCLIPath = "claudeCLIPath"
    static let composeAssistantMode = "composeAssistantMode"
    // Active AI features
    static let activeAIEnabled = "activeAIEnabled"
    static let nextCommandEnabled = "nextCommandEnabled"
    static let suggestedDiffsEnabled = "suggestedDiffsEnabled"
    static let activeAITelemetryEnabled = "activeAITelemetryEnabled"
    // Agent UX features
    static let agentInputBarEnabled = "agentInputBarEnabled"
    static let memoryToastsEnabled = "memoryToastsEnabled"
    static let ambientAgentEnabled = "ambientAgentEnabled"
    static let agentLoopEnabled = "agentLoopEnabled"
}
