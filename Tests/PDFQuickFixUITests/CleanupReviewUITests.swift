import XCTest

final class CleanupReviewUITests: XCTestCase {
    func testReaderSanitizedExportPresentsEvidenceAndComparison() throws {
        try verifySanitizedExportReview(mode: "reader")
    }

    func testStudioSanitizedExportPresentsEvidenceAndComparison() throws {
        try verifySanitizedExportReview(mode: "studio")
    }

    private func verifySanitizedExportReview(mode: String) throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-cleanup-review", mode]
        app.launch()

        XCTAssertTrue(
            app.staticTexts["ui-test-fixture-ready"].waitForExistence(timeout: 15),
            "The deterministic cleanup fixture did not finish opening in \(mode)."
        )

        app.menuBars.menuBarItems["File"].click()
        let exportMenuItem = app.menuBars.menuItems["Export"]
        XCTAssertTrue(exportMenuItem.waitForExistence(timeout: 5))
        exportMenuItem.hover()

        let sanitizeMenuItem = app.menuBars.menuItems["Sanitize for Sharing…"]
        XCTAssertTrue(sanitizeMenuItem.waitForExistence(timeout: 5))
        sanitizeMenuItem.click()

        let saveDialog = app.dialogs.firstMatch
        let savePanel: XCUIElement
        if saveDialog.waitForExistence(timeout: 3) {
            savePanel = saveDialog
        } else {
            let saveSheet = app.sheets.firstMatch
            XCTAssertTrue(saveSheet.waitForExistence(timeout: 3))
            savePanel = saveSheet
        }
        savePanel.buttons["Save"].click()

        XCTAssertTrue(app.staticTexts["Cleanup Evidence"].waitForExistence(timeout: 30))
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        XCTAssertTrue(app.staticTexts["Sanitized Export"].exists)
        let verdict = app.descendants(matching: .any)["cleanup-evidence-verdict"]
        XCTAssertTrue(
            verdict.waitForExistence(timeout: 5),
            "The cleanup verdict was not exposed to accessibility."
        )
        XCTAssertEqual(verdict.label, "Passed")

        let beforeAfter = app.descendants(matching: .any)["cleanup-review-tab-comparison"]
        let beforeAfterReady = expectation(
            for: NSPredicate(format: "exists == true AND hittable == true"),
            evaluatedWith: beforeAfter
        )
        guard XCTWaiter.wait(for: [beforeAfterReady], timeout: 5) == .completed else {
            XCTFail("The Before / After control did not become interactive.")
            return
        }
        beforeAfter.click()

        XCTAssertTrue(app.staticTexts["Before / After Cleanup"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Before"].exists)
        XCTAssertTrue(app.staticTexts["After"].exists)
    }
}
