// TabRenameUITests.swift
// CalyxUITests
//
// E2E tests for tab rename via double-click in the sidebar.
//
// Coverage:
// - Double-click tab → type new name → Enter → name changes
// - Double-click tab → Escape → name unchanged
// - Double-click inactive tab → enters edit mode without switching
// - Edit mode → click elsewhere → commits the rename
// - Edit mode → clear text → Enter → clears titleOverride (reverts to original title)

import XCTest

final class TabRenameUITests: CalyxUITestCase {

    // MARK: - Helpers

    /// Creates a second tab via menu and waits for it to appear.
    private func createSecondTab() {
        createNewTabViaMenu()
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(countTabBarTabs(), 2, "Should have two tabs after creating a new one")
    }

    // MARK: - Tests

    func test_renameTabByDoubleClick() {
        // Arrange: find the tab row in the sidebar
        let tabRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "calyx.sidebar.tab."))
            .firstMatch
        XCTAssertTrue(
            waitFor(tabRow, timeout: 5),
            "At least one tab should exist in the sidebar"
        )

        // Act: double-click to enter rename mode
        tabRow.doubleClick()

        // Wait for the rename text field to appear
        let renameField = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "calyx.sidebar.tabNameTextField."))
            .firstMatch
        XCTAssertTrue(
            waitFor(renameField, timeout: 3),
            "Rename text field should appear after double-clicking tab row"
        )

        // Select all existing text, type the new name and confirm with Enter
        renameField.typeKey("a", modifierFlags: .command)
        renameField.typeText("My Custom Tab")
        renameField.typeKey(.enter, modifierFlags: [])

        // Wait for the text field to dismiss
        waitForNonExistence(renameField)

        // Assert: the sidebar should now show "My Custom Tab"
        Thread.sleep(forTimeInterval: 0.5)
        let renamedLabel = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "My Custom Tab"))
            .firstMatch
        XCTAssertTrue(
            waitFor(renamedLabel, timeout: 3),
            "Sidebar should display the renamed tab 'My Custom Tab'"
        )
    }

    func test_renameTabCancel() {
        // Arrange: find the tab row in the sidebar
        let tabRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "calyx.sidebar.tab."))
            .firstMatch
        XCTAssertTrue(waitFor(tabRow, timeout: 5), "Tab should exist in the sidebar")

        // Capture the original label
        let originalLabel = tabRow.label

        // Act: double-click to enter rename mode
        tabRow.doubleClick()

        // Wait for the rename text field to appear
        let renameField = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "calyx.sidebar.tabNameTextField."))
            .firstMatch
        XCTAssertTrue(
            waitFor(renameField, timeout: 3),
            "Rename text field should appear after double-clicking tab row"
        )

        // Type something then cancel with Escape
        renameField.typeKey("a", modifierFlags: .command)
        renameField.typeText("Should Not Save")
        renameField.typeKey(.escape, modifierFlags: [])

        // Assert: the text field should disappear
        waitForNonExistence(renameField)

        // Assert: original name should still be displayed
        Thread.sleep(forTimeInterval: 0.5)
        let restoredLabel = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", originalLabel))
            .firstMatch
        XCTAssertTrue(
            waitFor(restoredLabel, timeout: 3),
            "Original tab name should still be displayed after cancelling rename"
        )
    }

    func test_renameInactiveTab() {
        // Arrange: create a second tab so we have an inactive one
        createSecondTab()

        // The first (inactive) tab in the sidebar
        let sidebarTabs = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT identifier CONTAINS %@", "calyx.sidebar.tab.", "closeButton"))
        XCTAssertGreaterThanOrEqual(sidebarTabs.count, 2, "Should have at least 2 sidebar tab rows")

        // The first tab is inactive (the second was just created and is active)
        let inactiveTab = sidebarTabs.element(boundBy: 0)
        XCTAssertTrue(inactiveTab.exists, "First sidebar tab should exist")

        // Act: double-click the inactive tab to enter rename mode
        inactiveTab.doubleClick()

        // Wait for the rename text field to appear
        let renameField = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "calyx.sidebar.tabNameTextField."))
            .firstMatch
        XCTAssertTrue(
            waitFor(renameField, timeout: 3),
            "Rename text field should appear after double-clicking inactive tab"
        )

        // Type new name and confirm
        renameField.typeKey("a", modifierFlags: .command)
        renameField.typeText("Renamed Inactive")
        renameField.typeKey(.enter, modifierFlags: [])

        // Wait for the text field to dismiss
        waitForNonExistence(renameField)

        // Assert: the renamed label should appear
        Thread.sleep(forTimeInterval: 0.5)
        let renamedLabel = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Renamed Inactive"))
            .firstMatch
        XCTAssertTrue(
            waitFor(renamedLabel, timeout: 3),
            "Inactive tab should be renamed to 'Renamed Inactive'"
        )
    }

    func test_renameTabClickOutsideCommits() {
        // Arrange: find the tab row in the sidebar
        let tabRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "calyx.sidebar.tab."))
            .firstMatch
        XCTAssertTrue(waitFor(tabRow, timeout: 5), "Tab should exist in the sidebar")

        // Act: double-click to enter rename mode
        tabRow.doubleClick()

        // Wait for the rename text field to appear
        let renameField = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "calyx.sidebar.tabNameTextField."))
            .firstMatch
        XCTAssertTrue(
            waitFor(renameField, timeout: 3),
            "Rename text field should appear after double-clicking tab row"
        )

        // Type new name
        renameField.typeKey("a", modifierFlags: .command)
        renameField.typeText("Click Outside Name")

        // Click elsewhere (the main window area, outside the sidebar) to commit
        app.windows.firstMatch
            .coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5))
            .click()

        // Wait for the text field to dismiss
        waitForNonExistence(renameField)

        // Assert: the new name should be committed
        Thread.sleep(forTimeInterval: 0.5)
        let committedLabel = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Click Outside Name"))
            .firstMatch
        XCTAssertTrue(
            waitFor(committedLabel, timeout: 3),
            "Tab name should be committed to 'Click Outside Name' after clicking outside"
        )
    }

    func test_renameTabEmptyStringClearsOverride() {
        // Arrange: first rename the tab to have a titleOverride
        let tabRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "calyx.sidebar.tab."))
            .firstMatch
        XCTAssertTrue(waitFor(tabRow, timeout: 5), "Tab should exist in the sidebar")

        // Set an initial override
        tabRow.doubleClick()

        let renameField = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "calyx.sidebar.tabNameTextField."))
            .firstMatch
        XCTAssertTrue(
            waitFor(renameField, timeout: 3),
            "Rename text field should appear"
        )

        renameField.typeKey("a", modifierFlags: .command)
        renameField.typeText("Temporary Name")
        renameField.typeKey(.enter, modifierFlags: [])
        waitForNonExistence(renameField)

        // Verify the override is in place
        Thread.sleep(forTimeInterval: 0.5)
        let tempLabel = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", "Temporary Name"))
            .firstMatch
        XCTAssertTrue(
            waitFor(tempLabel, timeout: 3),
            "Tab should be renamed to 'Temporary Name'"
        )

        // Act: double-click again, clear the text, and confirm
        tabRow.doubleClick()

        let renameField2 = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "calyx.sidebar.tabNameTextField."))
            .firstMatch
        XCTAssertTrue(
            waitFor(renameField2, timeout: 3),
            "Rename text field should appear again"
        )

        renameField2.typeKey("a", modifierFlags: .command)
        renameField2.typeKey(.delete, modifierFlags: [])
        renameField2.typeKey(.enter, modifierFlags: [])

        // Wait for the text field to dismiss
        waitForNonExistence(renameField2)

        // Assert: "Temporary Name" should no longer be displayed (reverted to original title)
        Thread.sleep(forTimeInterval: 0.5)
        let tempLabelAfter = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Temporary Name"))
            .firstMatch
        XCTAssertFalse(
            tempLabelAfter.exists,
            "Tab should revert to original title after clearing titleOverride with empty string"
        )
    }
}
