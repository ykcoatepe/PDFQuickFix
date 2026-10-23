import XCTest

final class StudioInspectorUITests: XCTestCase {
    func testToolsMenuOpensFormsAndInsertsFieldInCurrentDocument() {
        let app = launchStudio()
        selectTool("Forms", in: app)
        let name = app.textFields["studio-form-field-name"]
        guard require(name.waitForExistence(timeout: 5), in: app, stage: "input-present",
                      message: "Forms must expose the field-name input") else { return }
        guard assertValue("", of: name, in: app, stage: "initial-input",
                          message: "A fresh Forms inspector must start with an empty field name") else { return }
        let fieldCount = app.descendants(matching: .any)["studio-form-field-count"]
        guard assertValue("0", of: fieldCount, in: app, stage: "initial-field-count",
                          message: "The fixture must start without form fields") else { return }
        name.click()
        name.typeKey("a", modifierFlags: .command)
        let fieldName = "Inspector regression field"
        name.typeText(fieldName)
        guard assertValue(fieldName, of: name, in: app, stage: "entered-name",
                          message: "The complete requested name must reach the input before insertion") else { return }
        let insert = app.buttons["studio-insert-form-field"]
        guard require(insert.isEnabled, in: app, stage: "insert-enabled",
                      message: "Insert Field must be available for the opened fixture") else { return }
        insert.click()
        guard assertValue("1", of: fieldCount, in: app, stage: "inserted-field-count",
                          message: "Insert Field must publish a real form annotation in the current document") else { return }
        let fieldRow = app.descendants(matching: .any)["studio-form-field-row-\(fieldName)"]
        guard require(fieldRow.waitForExistence(timeout: 5), in: app, stage: "inserted-field-row",
                      message: "The newly inserted annotation must expose its named row") else { return }
        guard require(fieldRow.label == fieldName, in: app, stage: "inserted-field-name",
                      message: "The annotation row must retain the exact requested field name") else { return }

        selectTool("Organize", in: app)
        XCTAssertTrue(app.buttons["Duplicate"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["studio-insert-form-field"].exists)
        selectTool("Forms", in: app)
        guard assertValue("1", of: fieldCount, in: app, stage: "remounted-field-count",
                          message: "Changing inspectors must preserve the inserted annotation") else { return }
        guard require(fieldRow.waitForExistence(timeout: 5), in: app, stage: "remounted-field-row",
                      message: "Changing inspectors must preserve the named annotation row") else { return }
        _ = require(fieldRow.label == fieldName, in: app, stage: "remounted-field-name",
                    message: "The remounted row must retain the exact requested field name")
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

    @discardableResult
    private func assertValue(_ value: String, of element: XCUIElement, in app: XCUIApplication? = nil,
                             stage: String = "value", message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) -> Bool
    {
        let matches = expectation(for: NSPredicate(format: "exists == true AND value == %@", value), evaluatedWith: element)
        let result = XCTWaiter.wait(for: [matches], timeout: 5)
        if result != .completed, let app { captureDiagnostics(in: app, stage: stage) }
        XCTAssertEqual(result, .completed, message, file: file, line: line)
        return result == .completed
    }

    private func require(_ condition: Bool, in app: XCUIApplication, stage: String, message: String,
                         file: StaticString = #filePath, line: UInt = #line) -> Bool
    {
        if !condition {
            captureDiagnostics(in: app, stage: stage)
            XCTFail(message, file: file, line: line)
        }
        return condition
    }

    private func captureDiagnostics(in app: XCUIApplication, stage: String) {
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Studio Forms - \(stage) - accessibility hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Studio Forms - \(stage) - screenshot"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        print("Studio Forms diagnostic stage: \(stage), application state: \(app.state.rawValue)")
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
