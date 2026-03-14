// BrowserScriptingUITests.swift
// CalyxUITests
//
// E2E tests for browser scripting enable/disable via command palette.

import XCTest

final class BrowserScriptingUITests: CalyxUITestCase {

    private func openCommandPalette() {
        openCommandPaletteViaMenu()
        let searchField = app.descendants(matching: .any)
            .matching(identifier: "calyx.commandPalette.searchField")
            .firstMatch
        XCTAssertTrue(waitFor(searchField), "Command palette should appear")
    }

    private func searchAndExecute(_ query: String) {
        let searchField = app.descendants(matching: .any)
            .matching(identifier: "calyx.commandPalette.searchField")
            .firstMatch
        searchField.typeText(query)
        Thread.sleep(forTimeInterval: 0.3)
        searchField.typeKey(.enter, modifierFlags: [])
    }

    func test_enableBrowserScripting() {
        // Open command palette and search for enable scripting
        openCommandPalette()

        let searchField = app.descendants(matching: .any)
            .matching(identifier: "calyx.commandPalette.searchField")
            .firstMatch
        searchField.typeText("Enable Browser Scripting")
        Thread.sleep(forTimeInterval: 0.3)

        let resultsTable = app.descendants(matching: .any)
            .matching(identifier: "calyx.commandPalette.resultsTable")
            .firstMatch
        XCTAssertTrue(resultsTable.exists, "Results should show")
        XCTAssertGreaterThan(resultsTable.tableRows.count, 0, "Should find Enable Browser Scripting command")

        // Execute it
        searchField.typeKey(.enter, modifierFlags: [])

        // Warning dialog should appear
        let warningDialog = app.dialogs.firstMatch
        XCTAssertTrue(warningDialog.waitForExistence(timeout: 3), "Warning dialog should appear")

        // Click Enable
        warningDialog.buttons["Enable"].click()

        // Now verify: open palette again and search — should find "Disable" not "Enable"
        Thread.sleep(forTimeInterval: 0.5)
        openCommandPalette()
        let searchField2 = app.descendants(matching: .any)
            .matching(identifier: "calyx.commandPalette.searchField")
            .firstMatch
        searchField2.typeText("Disable Browser Scripting")
        Thread.sleep(forTimeInterval: 0.3)

        let resultsTable2 = app.descendants(matching: .any)
            .matching(identifier: "calyx.commandPalette.resultsTable")
            .firstMatch
        XCTAssertGreaterThan(resultsTable2.tableRows.count, 0, "Should find Disable Browser Scripting after enabling")

        // Dismiss
        app.typeKey(.escape, modifierFlags: [])
    }

    func test_disableBrowserScripting() {
        // First enable it through UI
        openCommandPalette()
        searchAndExecute("Enable Browser Scripting")

        let enableDialog = app.dialogs.firstMatch
        if enableDialog.waitForExistence(timeout: 3) {
            enableDialog.buttons["Enable"].click()
        }

        Thread.sleep(forTimeInterval: 0.5)

        // Now disable it through UI
        openCommandPalette()
        searchAndExecute("Disable Browser Scripting")

        // Confirmation dialog should appear
        let dialog = app.dialogs.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 3), "Confirmation dialog should appear")
        dialog.buttons["OK"].click()

        // Verify: palette should now show Enable, not Disable
        Thread.sleep(forTimeInterval: 0.5)
        openCommandPalette()
        let searchField = app.descendants(matching: .any)
            .matching(identifier: "calyx.commandPalette.searchField")
            .firstMatch
        searchField.typeText("Enable Browser Scripting")
        Thread.sleep(forTimeInterval: 0.3)

        let resultsTable = app.descendants(matching: .any)
            .matching(identifier: "calyx.commandPalette.resultsTable")
            .firstMatch
        XCTAssertGreaterThan(resultsTable.tableRows.count, 0, "Should find Enable Browser Scripting after disabling")

        app.typeKey(.escape, modifierFlags: [])
    }

    func test_browserTabWithScriptingEnabled() {
        // Enable scripting first
        openCommandPalette()
        let searchField = app.descendants(matching: .any)
            .matching(identifier: "calyx.commandPalette.searchField")
            .firstMatch
        searchField.typeText("Enable Browser Scripting")
        Thread.sleep(forTimeInterval: 0.3)
        searchField.typeKey(.enter, modifierFlags: [])

        let warningDialog = app.dialogs.firstMatch
        if warningDialog.waitForExistence(timeout: 3) {
            warningDialog.buttons["Enable"].click()
        }

        Thread.sleep(forTimeInterval: 0.5)

        // Open a browser tab
        menuAction("File", item: "New Browser Tab")
        let urlDialog = app.dialogs.firstMatch
        XCTAssertTrue(urlDialog.waitForExistence(timeout: 5), "URL dialog should appear")

        let textField = urlDialog.textFields.firstMatch
        if textField.waitForExistence(timeout: 2) {
            textField.click()
            textField.typeText("https://example.com")
        }
        urlDialog.buttons["Open"].click()

        // Verify browser toolbar appears
        let toolbar = app.descendants(matching: .any)
            .matching(identifier: "calyx.browser.toolbar")
            .firstMatch
        XCTAssertTrue(waitFor(toolbar, timeout: 15), "Browser toolbar should appear")
    }

    func test_enableIPCShowsDialog() {
        openCommandPalette()
        searchAndExecute("Enable AI Agent IPC")

        // IPC enabled dialog should appear
        let dialog = app.dialogs.firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 5), "IPC dialog should appear")
        dialog.buttons["OK"].click()
    }
}
