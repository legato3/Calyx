// GitState.swift
// Calyx
//
// Observable model for all git source-control state within a window.
// Extracted from WindowSession to keep UI layout state and git data separate.

import Foundation

@Observable @MainActor
final class GitState {
    var changesState: GitChangesState = .notLoaded
    var entries: [GitFileEntry] = []
    var commits: [GitCommit] = []
    var expandedCommitIDs: Set<String> = []
    var commitFiles: [String: [CommitFileEntry]] = [:]
    /// Maps working-directory paths to their resolved git repo root.
    var repoRoots: [String: String] = [:]
}
