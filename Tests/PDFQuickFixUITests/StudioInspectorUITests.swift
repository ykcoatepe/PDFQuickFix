import XCTest

final class StudioInspectorUITests: XCTestCase {
    func testToolsMenuOpensFormsAndInsertsFieldInCurrentDocument() {
        let app = launchStudio()
        selectTool("Forms", in: app)
        let name = app.textFields["studio-form-field-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        let fieldName = "Inspector regression field"
        name.typeText(fieldName)
        let insert = app.buttons["studio-insert-form-field"]
        XCTAssertTrue(insert.isEnabled)
        insert.click()
        let fieldRow = app.descendants(matching: .any)["studio-form-field-row-\(fieldName)"]
        XCTAssertTrue(fieldRow.waitForExistence(timeout: 5))
        XCTAssertEqual(fieldRow.label, fieldName)

        selectTool("Organize", in: app)
        XCTAssertTrue(app.buttons["Duplicate"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["studio-insert-form-field"].exists)
        selectTool("Forms", in: app)
        XCTAssertTrue(fieldRow.waitForExistence(timeout: 5), "Changing inspectors must preserve edits in the current document")
        XCTAssertEqual(fieldRow.label, fieldName)
    }

    func testOrganizeAddsBlankPageAndSignInspectorIsReachable() {
        let app = launchStudio()
        selectTool("Organize", in: app)
        let pageCount = app.descendants(matching: .any)["studio-organizer-page-count"]
        assertValue("1", of: pageCount)
        let add = app.descendants(matching: .any)["studio-organizer-add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.click()
        let blankPage = app.menuItems["Blank Page"]
        XCTAssertTrue(blankPage.waitForExistence(timeout: 5))
        blankPage.click()
        assertValue("2", of: pageCount, message: "Adding a blank page must increment the current document from 1 page to 2")
        XCTAssertTrue(app.buttons["Duplicate"].isEnabled)

        selectTool("Sign", in: app)
        XCTAssertTrue(app.staticTexts["Create your signature"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["studio-tool-picker"].exists)
    }

    private func assertValue(_ value: String, of element: XCUIElement, message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        let matches = expectation(for: NSPredicate(format: "exists == true AND value == %@", value), evaluatedWith: element)
        XCTAssertEqual(XCTWaiter.wait(for: [matches], timeout: 5), .completed, message, file: file, line: line)
    }

    private func launchStudio() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-cleanup-review", "studio"]
        app.launch()
        XCTAssertTrue(app.staticTexts["ui-test-fixture-ready"].waitForExistence(timeout: 15))
        return app
    }

    private func selectTool(_ tool: String, in app: XCUIApplication) {
        app.menuBars.menuBarItems["Tools"].click()
        let item = app.menuBars.menuItems[tool]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.click()
    }
}
