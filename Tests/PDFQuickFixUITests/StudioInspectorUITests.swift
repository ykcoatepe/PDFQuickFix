import XCTest

final class StudioInspectorUITests: XCTestCase {
    func testToolsMenuOpensFormsAndInsertsFieldInCurrentDocument() {
        let app = launchStudio()
        selectTool("Forms", in: app)
        let name = app.textFields["studio-form-field-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click()
        name.typeText("Inspector regression field")
        let insert = app.buttons["studio-insert-form-field"]
        XCTAssertTrue(insert.isEnabled)
        insert.click()
        XCTAssertTrue(app.staticTexts["Inspector regression field"].waitForExistence(timeout: 5))

        selectTool("Organize", in: app)
        XCTAssertTrue(app.buttons["Duplicate"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["studio-insert-form-field"].exists)
        selectTool("Forms", in: app)
        XCTAssertTrue(app.staticTexts["Inspector regression field"].waitForExistence(timeout: 5), "Changing inspectors must preserve edits in the current document")
    }

    func testOrganizeAddsBlankPageAndSignInspectorIsReachable() {
        let app = launchStudio()
        selectTool("Organize", in: app)
        let add = app.menuButtons["Add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.click()
        let blankPage = app.menuItems["Blank Page"]
        XCTAssertTrue(blankPage.waitForExistence(timeout: 5))
        blankPage.click()
        XCTAssertTrue(app.staticTexts["Page 2"].waitForExistence(timeout: 5), "The organizer must act on the currently open single-page fixture")
        XCTAssertTrue(app.buttons["Duplicate"].isEnabled)

        selectTool("Sign", in: app)
        XCTAssertTrue(app.staticTexts["Create your signature"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["studio-tool-picker"].exists)
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
