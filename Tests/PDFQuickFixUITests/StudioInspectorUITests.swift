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
        let formsScroll = app.scrollViews["studio-forms-scroll"]
        let insert = app.buttons["studio-insert-form-field"]
        guard scrollIntoView(insert, in: formsScroll, app: app, stage: "insert-visible") else { return }
        guard require(insert.isEnabled, in: app, stage: "insert-enabled",
                      message: "Insert Field must be available for the opened fixture") else { return }
        insert.click()
        guard assertValue("1", of: fieldCount, in: app, stage: "inserted-field-count",
                          message: "Insert Field must publish a real form annotation in the current document") else { return }
        guard verifyNamedField(fieldName, in: app, scrollView: formsScroll, stage: "inserted-field") else { return }

        selectTool("Organize", in: app)
        XCTAssertTrue(app.buttons["Duplicate"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["studio-insert-form-field"].exists)
        selectTool("Forms", in: app)
        guard assertValue("1", of: fieldCount, in: app, stage: "remounted-field-count",
                          message: "Changing inspectors must preserve the inserted annotation") else { return }
        _ = verifyNamedField(fieldName, in: app, scrollView: formsScroll, stage: "remounted-field")
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

    private func verifyNamedField(_ name: String, in app: XCUIApplication, scrollView: XCUIElement, stage: String) -> Bool {
        let fieldsList = app.descendants(matching: .any)["studio-form-fields-list"]
        guard require(fieldsList.waitForExistence(timeout: 5), in: app, stage: "\(stage)-list",
                      message: "Existing annotations must expose their actual fields list") else { return false }
        // Native List rows aggregate the name, page and kind. Match an exact first line, never a substring
        // or the name-entry TextField outside this list. Row roles and custom child IDs differ by macOS.
        let predicate = NSPredicate(
            format: "elementType != %d AND (value == %@ OR value BEGINSWITH %@ OR label == %@ OR label BEGINSWITH %@)",
            XCUIElement.ElementType.textField.rawValue, name, name + "\n", name, name + "\n"
        )
        let field = fieldsList.descendants(matching: .any).matching(predicate).firstMatch
        guard scrollIntoView(field, in: scrollView, app: app, stage: "\(stage)-visible") else { return false }
        let valueName = (field.value as? String)?.components(separatedBy: .newlines).first
        let labelName = field.label.components(separatedBy: .newlines).first
        return require(valueName == name || labelName == name, in: app, stage: "\(stage)-exact-name",
                       message: "The actual annotation list must retain the exact requested field-name line")
    }

    private func scrollIntoView(_ element: XCUIElement, in scrollView: XCUIElement,
                                app: XCUIApplication, stage: String) -> Bool
    {
        guard require(scrollView.waitForExistence(timeout: 5), in: app, stage: "\(stage)-scroll-view",
                      message: "Forms must expose its own scrolling viewport") else { return false }
        for attempt in 0 ... 8 {
            let viewport = scrollView.frame
            if element.exists {
                let target = element.frame
                if !target.isEmpty, viewport.contains(target), element.isHittable { return true }
            }
            guard attempt < 8 else { break }
            // Scroll only this inspector. Positive wheel delta moves toward earlier controls on macOS.
            let above = element.exists && element.frame.minY < viewport.minY
            scrollView.scroll(byDeltaX: 0, deltaY: above ? 80 : -80)
        }
        return require(false, in: app, stage: stage,
                       message: "The Forms target must be hittable and fully inside its viewport before interaction or inspection")
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
