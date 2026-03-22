// DiffTabLifecycleTests.swift
// CalyxTests
//
// Tests for diff tab lifecycle: GitChangesState transitions, SidebarMode, DiffSource dedup.

import Testing
@testable import Calyx

@MainActor
struct DiffTabLifecycleTests {
    @Test func gitChangesStateTransitions() {
        let session = WindowSession()
        if case .notLoaded = session.git.changesState {} else {
            Issue.record("Expected initial state .notLoaded")
        }

        session.git.changesState = .loading
        if case .loading = session.git.changesState {} else {
            Issue.record("Expected .loading")
        }

        session.git.changesState = .loaded
        if case .loaded = session.git.changesState {} else {
            Issue.record("Expected .loaded")
        }
    }

    @Test func gitChangesStateNotRepository() {
        let session = WindowSession()
        session.git.changesState = .loading
        session.git.changesState = .notRepository
        if case .notRepository = session.git.changesState {} else {
            Issue.record("Expected .notRepository")
        }
    }

    @Test func gitChangesStateError() {
        let session = WindowSession()
        session.git.changesState = .error("test error")
        if case .error(let msg) = session.git.changesState {
            #expect(msg == "test error")
        } else {
            Issue.record("Expected .error")
        }
    }

    @Test func sidebarModeToggle() {
        let session = WindowSession()
        #expect(session.sidebarMode == .tabs)
        session.sidebarMode = .changes
        #expect(session.sidebarMode == .changes)
        session.sidebarMode = .tabs
        #expect(session.sidebarMode == .tabs)
    }

    @Test func diffSourceDedup() {
        let a = DiffSource.unstaged(path: "foo.swift", workDir: "/repo")
        let b = DiffSource.unstaged(path: "foo.swift", workDir: "/repo")
        #expect(a == b)

        let c = DiffSource.staged(path: "foo.swift", workDir: "/repo")
        #expect(a != c)

        let d = DiffSource.commit(hash: "abc", path: "foo.swift", workDir: "/repo")
        #expect(a != d)
    }
}
