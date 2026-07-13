import AppKit
import PDFKit
@testable import PDFQuickFix
import XCTest

@MainActor
final class StudioControllerTests: XCTestCase {
    private func makeSolidColorDocument(colors: [NSColor], size: CGSize = CGSize(width: 80, height: 80)) -> PDFDocument {
        let document = PDFDocument()

        for (index, color) in colors.enumerated() {
            let image = NSImage(size: size)
            image.lockFocus()
            color.setFill()
            NSRect(origin: .zero, size: size).fill()
            image.unlockFocus()

            if let page = PDFPage(image: image) {
                document.insert(page, at: index)
            }
        }

        return document
    }

    private func makeSignatureImage() -> NSImage {
        let image = NSImage(size: CGSize(width: 400, height: 120))
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        NSColor.black.setStroke()
        let path = NSBezierPath()
        path.move(to: CGPoint(x: 24, y: 52))
        path.curve(to: CGPoint(x: 360, y: 64),
                   controlPoint1: CGPoint(x: 96, y: 110),
                   controlPoint2: CGPoint(x: 210, y: 8))
        path.lineWidth = 8
        path.stroke()
        image.unlockFocus()
        return image
    }

    func testDuplicateSelectedPagesPreservesOriginalIndicesForMultipleSelections() {
        let controller = StudioController()
        let colors: [NSColor] = [.red, .green, .blue, .yellow]
        controller.document = makeSolidColorDocument(colors: colors)
        controller.selectedPageIDs = [1, 3]

        XCTAssertTrue(controller.duplicateSelectedPages())
        XCTAssertEqual(controller.document?.pageCount, 6)

        let expectedColors: [NSColor] = [.red, .green, .green, .blue, .yellow, .yellow]
        for (index, expectedColor) in expectedColors.enumerated() {
            guard let page = controller.document?.page(at: index),
                  let rendered = TestPDFRenderer.render(page, size: CGSize(width: 80, height: 80)),
                  let sampled = rendered.color(at: CGPoint(x: 40, y: 40))
            else {
                XCTFail("Missing rendered page at index \(index)")
                return
            }
            XCTAssertTrue(sampled.isApproximately(expectedColor), "Unexpected color at page index \(index)")
        }
    }

    func testDuplicateSelectedPagesUndoRemovesClonesOnly() throws {
        let controller = StudioController()
        let pdfView = PDFView()
        controller.attach(pdfView: pdfView)
        let document = makeSolidColorDocument(colors: [.red, .green, .blue, .yellow])
        controller.document = document
        pdfView.document = document
        controller.selectedPageIDs = [1, 3]

        XCTAssertTrue(controller.duplicateSelectedPages())
        try assertPageColors(document, [.red, .green, .green, .blue, .yellow, .yellow])

        controller.undoLastEdit()

        try assertPageColors(document, [.red, .green, .blue, .yellow])
    }

    func testInsertBlankPageAddsPageAfterSelection() {
        let controller = StudioController()
        controller.document = makeSolidColorDocument(colors: [.red, .blue])
        controller.selectedPageIDs = [0]

        XCTAssertTrue(controller.insertBlankPage())
        XCTAssertEqual(controller.document?.pageCount, 3)
        XCTAssertEqual(controller.selectedPageIDs, [1])

        guard let blankPage = controller.document?.page(at: 1),
              let rendered = TestPDFRenderer.render(blankPage, size: CGSize(width: 80, height: 80)),
              let sampled = rendered.color(at: CGPoint(x: 40, y: 40))
        else {
            XCTFail("Missing rendered blank page")
            return
        }
        XCTAssertTrue(sampled.isApproximately(.white), "Inserted page should render as blank white")
    }

    func testInsertBlankPageCanUndo() {
        let controller = StudioController()
        let pdfView = PDFView()
        controller.attach(pdfView: pdfView)
        let document = makeSolidColorDocument(colors: [.red])
        controller.document = document
        pdfView.document = document

        XCTAssertTrue(controller.insertBlankPage(after: 0))
        XCTAssertEqual(document.pageCount, 2)

        controller.undoLastEdit()

        XCTAssertEqual(document.pageCount, 1)

        controller.redoLastEdit()

        XCTAssertEqual(document.pageCount, 2)
    }

    func testImportPagesInsertsCopiesAfterSelection() {
        let controller = StudioController()
        controller.document = makeSolidColorDocument(colors: [.red, .blue])
        controller.selectedPageIDs = [0]
        let source = makeSolidColorDocument(colors: [.green, .yellow])

        XCTAssertEqual(controller.importPages(from: source), 2)
        XCTAssertEqual(controller.document?.pageCount, 4)
        XCTAssertEqual(controller.selectedPageIDs, [1, 2])

        let expectedColors: [NSColor] = [.red, .green, .yellow, .blue]
        for (index, expectedColor) in expectedColors.enumerated() {
            guard let page = controller.document?.page(at: index),
                  let rendered = TestPDFRenderer.render(page, size: CGSize(width: 80, height: 80)),
                  let sampled = rendered.color(at: CGPoint(x: 40, y: 40))
            else {
                XCTFail("Missing rendered page at index \(index)")
                return
            }
            XCTAssertTrue(sampled.isApproximately(expectedColor), "Unexpected color at page index \(index)")
        }
    }

    func testMovePageCanUndoAndRedo() throws {
        let controller = StudioController()
        let pdfView = PDFView()
        controller.attach(pdfView: pdfView)
        let document = makeSolidColorDocument(colors: [.red, .green, .blue])
        controller.document = document
        pdfView.document = document

        controller.movePage(at: 0, to: 2)

        try assertPageColors(document, [.green, .blue, .red])
        XCTAssertEqual(controller.selectedPageIDs, [2])

        controller.undoLastEdit()

        try assertPageColors(document, [.red, .green, .blue])

        controller.redoLastEdit()

        try assertPageColors(document, [.green, .blue, .red])
        XCTAssertEqual(controller.selectedPageIDs, [2])
    }

    func testMovePagesCanUndoAndRedo() throws {
        let controller = StudioController()
        let pdfView = PDFView()
        controller.attach(pdfView: pdfView)
        let document = makeSolidColorDocument(colors: [.red, .green, .blue, .yellow])
        controller.document = document
        pdfView.document = document
        controller.selectedPageIDs = [1, 2]

        controller.movePages(from: IndexSet([1, 2]), to: 0)

        try assertPageColors(document, [.green, .blue, .red, .yellow])

        controller.undoLastEdit()

        try assertPageColors(document, [.red, .green, .blue, .yellow])
        XCTAssertEqual(controller.selectedPageIDs, [1, 2])

        controller.redoLastEdit()

        try assertPageColors(document, [.green, .blue, .red, .yellow])
        XCTAssertTrue(controller.selectedPageIDs.isEmpty)
    }

    func testDeleteSelectedPagesCanUndo() {
        let controller = StudioController()
        let pdfView = PDFView()
        controller.attach(pdfView: pdfView)
        let document = makeSolidColorDocument(colors: [.red, .blue])
        controller.document = document
        pdfView.document = document
        controller.selectedPageIDs = [1]

        XCTAssertTrue(controller.deleteSelectedPages())
        XCTAssertEqual(document.pageCount, 1)

        controller.undoLastEdit()

        XCTAssertEqual(document.pageCount, 2)
        XCTAssertEqual(controller.selectedPageIDs, [1])

        controller.redoLastEdit()

        XCTAssertEqual(document.pageCount, 1)
    }

    func testSetDocumentClearsStaleEditUndoStack() throws {
        let controller = StudioController()
        let pdfView = PDFView()
        controller.attach(pdfView: pdfView)
        let firstDocument = makeSolidColorDocument(colors: [.red, .green])
        controller.document = firstDocument
        pdfView.document = firstDocument
        controller.selectedPageIDs = [0]

        XCTAssertTrue(controller.deleteSelectedPages())
        XCTAssertEqual(firstDocument.pageCount, 1)

        let secondDocument = makeSolidColorDocument(colors: [.blue])
        controller.setDocument(secondDocument)
        controller.undoLastEdit()

        XCTAssertEqual(secondDocument.pageCount, 1)
        try assertPageColors(secondDocument, [.blue])
    }

    func testThumbnailSnapshotReusesDetachedDocumentWithoutSerializingLiveDocument() throws {
        let source = makeSolidColorDocument(colors: [.red, .green, .blue])
        let sourceData = try XCTUnwrap(source.dataRepresentation())
        let document = try XCTUnwrap(ThumbnailSnapshotTrackingDocument(data: sourceData))
        let controller = StudioController()

        controller.setDocument(document)
        controller.ensureThumbnail(for: 0)
        controller.ensureThumbnail(for: 1)
        controller.prefetchThumbnails(around: 1, window: 1, farWindow: 2)

        let thumbnailsRendered = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                controller.pageSnapshots.filter { $0.thumbnail != nil }.count >= 2
            },
            object: nil
        )
        wait(for: [thumbnailsRendered], timeout: 5.0)

        controller.ensureThumbnail(for: 2)
        controller.prefetchThumbnails(around: 2, window: 1, farWindow: 2)

        XCTAssertEqual(document.dataRepresentationCallCount, 0)
        XCTAssertFalse(document.dataRepresentationWasCalledOnMainThread)
    }

    func testFileBackedThumbnailUsesUnsavedPageOrder() throws {
        let source = makeSolidColorDocument(colors: [.red, .blue])
        let sourceData = try XCTUnwrap(source.dataRepresentation())
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pdfquickfix-thumbnail-\(UUID().uuidString).pdf")
        try sourceData.write(to: sourceURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let document = try XCTUnwrap(PDFDocument(url: sourceURL))
        let controller = StudioController()

        controller.setDocument(document, url: sourceURL)
        controller.movePage(at: 0, to: 1)
        controller.ensureThumbnail(for: 0)

        let thumbnailRendered = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                controller.pageSnapshots.first?.thumbnail != nil
            },
            object: nil
        )
        wait(for: [thumbnailRendered], timeout: 5.0)

        let thumbnail = try XCTUnwrap(controller.pageSnapshots.first?.thumbnail)
        let sampled = try XCTUnwrap(thumbnail.color(at: CGPoint(
            x: thumbnail.width / 2,
            y: thumbnail.height / 2
        )))
        XCTAssertTrue(sampled.isApproximately(.blue), "Thumbnail should reflect the unsaved page order")
    }

    func testAddedAnnotationCanUndoAndRedo() throws {
        let controller = StudioController()
        let pdfView = PDFView()
        controller.attach(pdfView: pdfView)
        let document = makeSolidColorDocument(colors: [.red])
        controller.document = document
        pdfView.document = document

        let page = try XCTUnwrap(document.page(at: 0))
        let baselineCount = realAnnotationCount(on: page)
        let annotation = try XCTUnwrap(EditingTools.addNote(in: pdfView, text: "Undoable note"))
        controller.registerAnnotationAddition(annotation, actionName: "Add Note")
        controller.refreshAnnotations()
        XCTAssertGreaterThan(page.annotations.count, baselineCount)
        XCTAssertTrue(page.annotations.contains { $0.contents == "Undoable note" })

        controller.undoLastEdit()

        XCTAssertEqual(page.annotations.count, baselineCount)

        controller.redoLastEdit()

        XCTAssertGreaterThan(page.annotations.count, baselineCount)
        XCTAssertTrue(page.annotations.contains { $0.contents == "Undoable note" })
    }

    func testDeletedAnnotationCanUndoAndRedo() throws {
        let controller = StudioController()
        let pdfView = PDFView()
        controller.attach(pdfView: pdfView)
        let document = makeSolidColorDocument(colors: [.red])
        controller.document = document
        pdfView.document = document
        let annotation = try XCTUnwrap(EditingTools.addRectangle(in: pdfView))
        controller.selectAnnotation(annotation)

        controller.deleteSelectedAnnotation()

        let page = try XCTUnwrap(document.page(at: 0))
        XCTAssertFalse(page.annotations.contains { $0 === annotation })

        controller.undoLastEdit()

        XCTAssertTrue(page.annotations.contains { $0 === annotation })

        controller.redoLastEdit()

        XCTAssertFalse(page.annotations.contains { $0 === annotation })
    }

    func testEditAnnotationContentsCanUndoAndRedo() throws {
        let controller = StudioController()
        let pdfView = PDFView()
        controller.attach(pdfView: pdfView)
        let document = makeSolidColorDocument(colors: [.red])
        controller.document = document
        pdfView.document = document
        let annotation = try XCTUnwrap(EditingTools.addNote(in: pdfView, text: "Original note"))
        controller.refreshAnnotations()
        let row = try XCTUnwrap(controller.annotationRows.first { $0.annotation === annotation })

        controller.editAnnotation(row, contents: "Updated note")

        XCTAssertEqual(annotation.contents, "Updated note")

        controller.undoLastEdit()

        XCTAssertEqual(annotation.contents, "Original note")

        controller.redoLastEdit()

        XCTAssertEqual(annotation.contents, "Updated note")
    }

    func testEditLinkAnnotationURLCanUndoAndRedo() throws {
        let controller = StudioController()
        let pdfView = PDFView()
        controller.attach(pdfView: pdfView)
        let document = makeSolidColorDocument(colors: [.red])
        controller.document = document
        pdfView.document = document
        let annotation = try XCTUnwrap(EditingTools.addLink(in: pdfView, urlString: "https://example.com"))
        annotation.contents = "Original link"
        controller.refreshAnnotations()
        let row = try XCTUnwrap(controller.annotationRows.first { $0.annotation === annotation })

        controller.editAnnotation(row, draft: AnnotationEditDraft(contents: "Updated link", urlString: "https://openai.com"))

        XCTAssertEqual(annotation.contents, "Updated link")
        XCTAssertEqual(annotation.url?.absoluteString, "https://openai.com")

        controller.undoLastEdit()

        XCTAssertEqual(annotation.contents, "Original link")
        XCTAssertEqual(annotation.url?.absoluteString, "https://example.com")

        controller.redoLastEdit()

        XCTAssertEqual(annotation.contents, "Updated link")
        XCTAssertEqual(annotation.url?.absoluteString, "https://openai.com")
    }

    func testStudioReplaceSelectedTextCanUndoAndRedo() throws {
        let controller = StudioController()
        let pdfView = PDFView()
        controller.attach(pdfView: pdfView)
        let document = try makeTextBackedDocument(text: "Replace me")
        controller.document = document
        pdfView.document = document
        let page = try XCTUnwrap(document.page(at: 0))
        let pageText = try XCTUnwrap(page.string)
        let selection = try XCTUnwrap(document.selection(from: page,
                                                         atCharacterIndex: 0,
                                                         to: page,
                                                         atCharacterIndex: pageText.count - 1))
        pdfView.setCurrentSelection(selection, animate: false)

        controller.replaceSelectedText(with: "Updated")

        XCTAssertEqual(page.annotations.filter { $0.type == "Square" }.count, 1)
        XCTAssertEqual(page.annotations.filter { $0.type == "FreeText" && $0.contents == "Updated" }.count, 1)

        controller.undoLastEdit()

        XCTAssertTrue(page.annotations.isEmpty)

        controller.redoLastEdit()

        XCTAssertEqual(page.annotations.filter { $0.type == "Square" }.count, 1)
        XCTAssertEqual(page.annotations.filter { $0.type == "FreeText" && $0.contents == "Updated" }.count, 1)
    }

    func testStudioReplaceSelectedTextAvailabilityTracksPDFSelectionNotifications() throws {
        let controller = StudioController()
        let pdfView = PDFView()
        controller.attach(pdfView: pdfView)
        let document = try makeTextBackedDocument(text: "Replace me")
        controller.document = document
        pdfView.document = document
        let page = try XCTUnwrap(document.page(at: 0))
        let pageText = try XCTUnwrap(page.string)
        let selection = try XCTUnwrap(document.selection(from: page,
                                                         atCharacterIndex: 0,
                                                         to: page,
                                                         atCharacterIndex: pageText.count - 1))

        XCTAssertFalse(controller.canReplaceSelectedText)

        pdfView.setCurrentSelection(selection, animate: false)
        NotificationCenter.default.post(name: .PDFViewSelectionChanged, object: pdfView)

        XCTAssertTrue(controller.canReplaceSelectedText)

        pdfView.clearSelection()
        NotificationCenter.default.post(name: .PDFViewSelectionChanged, object: pdfView)

        XCTAssertFalse(controller.canReplaceSelectedText)
    }

    func testStudioReplaceSelectedTextAddsReplacementForEachSelectedLine() throws {
        let controller = StudioController()
        let pdfView = PDFView()
        controller.attach(pdfView: pdfView)
        let document = try makeTextBackedDocument(text: "Replace first line\nReplace second line")
        controller.document = document
        pdfView.document = document
        let page = try XCTUnwrap(document.page(at: 0))
        let pageText = try XCTUnwrap(page.string)
        let selection = try XCTUnwrap(document.selection(from: page,
                                                         atCharacterIndex: 0,
                                                         to: page,
                                                         atCharacterIndex: pageText.count - 1))
        pdfView.setCurrentSelection(selection, animate: false)

        controller.replaceSelectedText(with: "Updated")

        let covers = page.annotations.filter { $0.type == "Square" }
        let replacements = page.annotations.filter { $0.type == "FreeText" && $0.contents == "Updated" }
        XCTAssertGreaterThan(covers.count, 1)
        XCTAssertEqual(replacements.count, covers.count)
    }

    func testStudioFindNavigationCyclesThroughMatches() throws {
        let controller = StudioController()
        let pdfView = PDFView()
        controller.attach(pdfView: pdfView)
        let document = try makeTextBackedDocument(text: "Needle one\nNeedle two")
        controller.document = document
        pdfView.document = document
        let matches = document.findString("Needle", withOptions: [.caseInsensitive])
        XCTAssertEqual(matches.count, 2)
        controller.searchMatches = matches

        controller.findNext()
        XCTAssertEqual(controller.currentMatchIndex, 0)

        controller.findNext()
        XCTAssertEqual(controller.currentMatchIndex, 1)

        controller.findPrev()
        XCTAssertEqual(controller.currentMatchIndex, 0)
    }

    func testStudioFindClearsMatchesForBlankQuery() throws {
        let controller = StudioController()
        let document = try makeTextBackedDocument(text: "Needle")
        controller.document = document
        controller.searchMatches = document.findString("Needle", withOptions: [])
        controller.currentMatchIndex = 0

        controller.find("   ")

        XCTAssertTrue(controller.searchMatches.isEmpty)
        XCTAssertNil(controller.currentMatchIndex)
    }

    func testStudioFindBlankQueryIgnoresStalePDFKitNotifications() async throws {
        let controller = StudioController()
        let document = try makeTextBackedDocument(text: "Needle")
        controller.document = document
        controller.find("Needle")

        controller.find("   ")

        let selection = try XCTUnwrap(document.findString("Needle", withOptions: []).first)
        NotificationCenter.default.post(name: .PDFDocumentDidFindMatch,
                                        object: document,
                                        userInfo: ["PDFDocumentFoundSelection": selection])
        await Task.yield()

        XCTAssertTrue(controller.searchMatches.isEmpty)
        XCTAssertNil(controller.currentMatchIndex)
    }

    func testStudioRedactSelectedTextCanUndoAndRedo() throws {
        let controller = StudioController()
        let pdfView = PDFView()
        controller.attach(pdfView: pdfView)
        let document = try makeTextBackedDocument(text: "Redact me")
        controller.document = document
        pdfView.document = document
        let page = try XCTUnwrap(document.page(at: 0))
        let pageText = try XCTUnwrap(page.string)
        let selection = try XCTUnwrap(document.selection(from: page,
                                                         atCharacterIndex: 0,
                                                         to: page,
                                                         atCharacterIndex: pageText.count - 1))
        pdfView.setCurrentSelection(selection, animate: false)

        controller.redactSelectedText()

        let redactions = page.annotations.filter {
            $0.type == "Square" &&
                $0.userName == PDFOps.replacementTextAnnotationUserName &&
                $0.interiorColor == .black
        }
        XCTAssertEqual(redactions.count, 1)
        XCTAssertTrue(PDFOps.containsReplacementTextAnnotations(in: document))

        controller.undoLastEdit()

        XCTAssertTrue(page.annotations.isEmpty)

        controller.redoLastEdit()

        XCTAssertEqual(page.annotations.filter { $0.userName == PDFOps.replacementTextAnnotationUserName }.count, 1)
    }

    func testSelectedPageExportFlattensReplacementTextOverlays() throws {
        let controller = StudioController()
        let pdfView = PDFView()
        controller.attach(pdfView: pdfView)
        let document = try makeTextBackedDocument(text: "Secret selected text")
        controller.document = document
        pdfView.document = document
        controller.selectedPageIDs = [0]
        let page = try XCTUnwrap(document.page(at: 0))
        let pageText = try XCTUnwrap(page.string)
        let selection = try XCTUnwrap(document.selection(from: page,
                                                         atCharacterIndex: 0,
                                                         to: page,
                                                         atCharacterIndex: pageText.count - 1))
        pdfView.setCurrentSelection(selection, animate: false)
        controller.replaceSelectedText(with: "Public selected text")

        let data = try controller.selectedPagesExportData()
        let exported = try XCTUnwrap(PDFDocument(data: data))

        XCTAssertFalse((exported.string ?? "").contains("Secret selected text"))
        XCTAssertTrue(exported.page(at: 0)?.annotations.isEmpty ?? false)
    }

    func testAddedFormFieldCanUndoAndRedo() throws {
        let controller = StudioController()
        let pdfView = PDFView()
        controller.attach(pdfView: pdfView)
        let document = makeSolidColorDocument(colors: [.red])
        controller.document = document
        pdfView.document = document
        let page = try XCTUnwrap(document.page(at: 0))
        let baselineCount = realAnnotationCount(on: page)

        controller.addFormField(kind: .text,
                                name: "Customer name",
                                rect: CGRect(x: 10, y: 10, width: 120, height: 24))

        XCTAssertEqual(realAnnotationCount(on: page), baselineCount + 1)
        XCTAssertTrue(page.annotations.contains { $0.fieldName == "Customer name" })

        controller.undoLastEdit()

        XCTAssertEqual(realAnnotationCount(on: page), baselineCount)

        controller.redoLastEdit()

        XCTAssertEqual(realAnnotationCount(on: page), baselineCount + 1)
        XCTAssertTrue(page.annotations.contains { $0.fieldName == "Customer name" })
    }

    func testFormFieldRowsExposeOnlyWidgetAnnotationsAndCanDelete() throws {
        let controller = StudioController()
        let pdfView = PDFView()
        controller.attach(pdfView: pdfView)
        let document = makeSolidColorDocument(colors: [.red])
        controller.document = document
        pdfView.document = document
        let page = try XCTUnwrap(document.page(at: 0))

        controller.addFormField(kind: .checkbox,
                                name: "Approved",
                                rect: CGRect(x: 10, y: 10, width: 24, height: 24))
        let note = try XCTUnwrap(EditingTools.addNote(in: pdfView, text: "Not a form field"))
        controller.registerAnnotationAddition(note, actionName: "Add Note")
        controller.refreshAnnotations()

        XCTAssertEqual(controller.formFieldRows.count, 1)
        let fieldRow = try XCTUnwrap(controller.formFieldRows.first)
        XCTAssertEqual(fieldRow.annotation.fieldName, "Approved")

        controller.delete(annotation: fieldRow)

        XCTAssertFalse(page.annotations.contains { $0.fieldName == "Approved" })
        XCTAssertEqual(controller.formFieldRows.count, 0)
        XCTAssertTrue(page.annotations.contains { $0.contents == "Not a form field" })
    }

    func testChoiceFormFieldStoresSanitizedOptions() throws {
        let controller = StudioController()
        let pdfView = PDFView()
        controller.attach(pdfView: pdfView)
        let document = makeSolidColorDocument(colors: [.white])
        controller.document = document
        pdfView.document = document
        let page = try XCTUnwrap(document.page(at: 0))

        controller.addFormField(kind: .dropdown,
                                name: "Status",
                                rect: CGRect(x: 10, y: 10, width: 120, height: 24),
                                options: [" Draft ", "", "Approved"])

        let field = try XCTUnwrap(page.annotations.first { $0.fieldName == "Status" })
        XCTAssertEqual(field.widgetFieldType, .choice)
        XCTAssertFalse(field.isListChoice)
        XCTAssertEqual(field.choices, ["Draft", "Approved"])
        XCTAssertEqual(field.widgetStringValue, "Draft")
    }

    func testRadioFormFieldUsesButtonWidgetType() throws {
        let controller = StudioController()
        let pdfView = PDFView()
        controller.attach(pdfView: pdfView)
        let document = makeSolidColorDocument(colors: [.white])
        controller.document = document
        pdfView.document = document
        let page = try XCTUnwrap(document.page(at: 0))

        controller.addFormField(kind: .radio,
                                name: "Priority",
                                rect: CGRect(x: 10, y: 10, width: 24, height: 24))

        let field = try XCTUnwrap(page.annotations.first { $0.fieldName == "Priority" })
        XCTAssertEqual(field.widgetFieldType, .button)
        XCTAssertEqual(field.widgetControlType, try XCTUnwrap(PDFWidgetControlType.radioSafe))
    }

    func testSignatureStampCanUndoAndRedo() throws {
        let controller = StudioController()
        let pdfView = PDFView()
        controller.attach(pdfView: pdfView)
        let document = makeSolidColorDocument(colors: [.white], size: CGSize(width: 240, height: 180))
        controller.document = document
        pdfView.document = document
        let page = try XCTUnwrap(document.page(at: 0))
        let baselineCount = realAnnotationCount(on: page)

        controller.addSignatureStamp(image: makeSignatureImage(), width: 120)

        XCTAssertEqual(realAnnotationCount(on: page), baselineCount + 1)
        XCTAssertTrue(page.annotations.contains { $0 is ImageStampAnnotation && $0.contents == "Signature" })

        controller.undoLastEdit()

        XCTAssertEqual(realAnnotationCount(on: page), baselineCount)

        controller.redoLastEdit()

        XCTAssertEqual(realAnnotationCount(on: page), baselineCount + 1)
        XCTAssertTrue(page.annotations.contains { $0 is ImageStampAnnotation && $0.contents == "Signature" })
    }

    func testWatermarkCanUndoAndRedoAsBulkAnnotationEdit() throws {
        let controller = StudioController()
        let pdfView = PDFView()
        controller.attach(pdfView: pdfView)
        let document = makeSolidColorDocument(colors: [.red, .blue])
        controller.document = document
        pdfView.document = document

        try controller.applyWatermark(text: "DRAFT",
                                      fontSize: 12,
                                      color: .red,
                                      opacity: 0.5,
                                      rotation: 0,
                                      position: .center,
                                      margin: 10)

        XCTAssertEqual(countAnnotations(containing: "DRAFT", in: document), 2)

        controller.undoLastEdit()

        XCTAssertEqual(countAnnotations(containing: "DRAFT", in: document), 0)

        controller.redoLastEdit()

        XCTAssertEqual(countAnnotations(containing: "DRAFT", in: document), 2)
    }

    func testCropCanUndoAndRedo() throws {
        let controller = StudioController()
        let pdfView = PDFView()
        controller.attach(pdfView: pdfView)
        let document = makeSolidColorDocument(colors: [.red], size: CGSize(width: 200, height: 200))
        controller.document = document
        pdfView.document = document
        let page = try XCTUnwrap(document.page(at: 0))
        let originalBox = page.bounds(for: .mediaBox)

        try controller.crop(inset: 10, target: .allPages)

        XCTAssertEqual(page.bounds(for: .mediaBox).width, originalBox.width - 20)
        XCTAssertEqual(page.bounds(for: .mediaBox).height, originalBox.height - 20)

        controller.undoLastEdit()

        XCTAssertEqual(page.bounds(for: .mediaBox), originalBox)

        controller.redoLastEdit()

        XCTAssertEqual(page.bounds(for: .mediaBox).width, originalBox.width - 20)
        XCTAssertEqual(page.bounds(for: .mediaBox).height, originalBox.height - 20)
    }

    func testImportImageFileAddsImagePageAfterSelection() throws {
        let controller = StudioController()
        controller.document = makeSolidColorDocument(colors: [.red, .blue])
        controller.selectedPageIDs = [0]
        let imageURL = try makeSolidColorImageFile(color: .green)

        XCTAssertEqual(controller.importPages(from: [imageURL]), 1)
        XCTAssertEqual(controller.document?.pageCount, 3)
        XCTAssertEqual(controller.selectedPageIDs, [1])

        guard let page = controller.document?.page(at: 1),
              let rendered = TestPDFRenderer.render(page, size: CGSize(width: 80, height: 80)),
              let sampled = rendered.color(at: CGPoint(x: 40, y: 40))
        else {
            XCTFail("Missing imported image page")
            return
        }
        XCTAssertTrue(sampled.isApproximately(.green), "Imported image should render as a PDF page")
    }

    func testAddOutlineCreatesBookmarkForCurrentDocument() throws {
        let controller = StudioController()
        let document = makeSolidColorDocument(colors: [.red, .blue])
        controller.document = document

        controller.addOutline(title: "  Chapter 1  ")

        let root = try XCTUnwrap(document.outlineRoot)
        XCTAssertEqual(root.numberOfChildren, 1)
        let bookmark = try XCTUnwrap(root.child(at: 0))
        XCTAssertEqual(bookmark.label, "Chapter 1")
        XCTAssertTrue(bookmark.destination?.page === document.page(at: 0))
        XCTAssertEqual(controller.outlineRows.count, 1)
    }

    func testAddOutlineCanUndoAndRedoIncludingCreatedRoot() throws {
        let controller = StudioController()
        let document = makeSolidColorDocument(colors: [.red])
        controller.document = document

        controller.addOutline(title: "Intro")

        XCTAssertEqual(document.outlineRoot?.numberOfChildren, 1)

        controller.undoLastEdit()

        XCTAssertNil(document.outlineRoot)
        XCTAssertTrue(controller.outlineRows.isEmpty)

        controller.redoLastEdit()

        XCTAssertEqual(document.outlineRoot?.numberOfChildren, 1)
        XCTAssertEqual(document.outlineRoot?.child(at: 0)?.label, "Intro")
    }

    func testAddOutlinePreservesExistingVisibleBookmarksBeyondMassiveDocumentCap() throws {
        let controller = StudioController()
        let document = makeSolidColorDocument(colors: [.red])
        let page = try XCTUnwrap(document.page(at: 0))
        let root = PDFOutline()
        root.label = "Bookmarks"

        for index in 0 ..< PDFOutlineLoader.massiveDocumentRowLimit {
            let outline = PDFOutline()
            outline.label = "Loaded \(index)"
            outline.destination = PDFDestination(page: page, at: .zero)
            root.insertChild(outline, at: root.numberOfChildren)
        }

        let firstAdded = PDFOutline()
        firstAdded.label = "First added"
        firstAdded.destination = PDFDestination(page: page, at: .zero)
        root.insertChild(firstAdded, at: root.numberOfChildren)
        document.outlineRoot = root

        controller.document = document
        controller.isMassiveDocument = true
        controller.refreshOutline(preserving: [firstAdded])
        XCTAssertTrue(controller.outlineRows.contains { $0.outline === firstAdded })

        let secondAdded = PDFOutline()
        secondAdded.label = "Second added"
        secondAdded.destination = PDFDestination(page: page, at: .zero)
        root.insertChild(secondAdded, at: root.numberOfChildren)

        controller.refreshOutline(preserving: [secondAdded])

        XCTAssertEqual(controller.outlineRows.count, PDFOutlineLoader.massiveDocumentRowLimit + 2)
        XCTAssertTrue(controller.outlineRows.contains { $0.outline === firstAdded })
        XCTAssertTrue(controller.outlineRows.contains { $0.outline === secondAdded })
    }

    func testRenameAndDeleteOutlineUpdatesBookmarkRows() throws {
        let controller = StudioController()
        let document = makeSolidColorDocument(colors: [.red])
        controller.document = document
        controller.addOutline(title: "Draft")
        let row = try XCTUnwrap(controller.outlineRows.first)

        controller.renameOutline(row, title: "  Final  ")

        XCTAssertEqual(row.outline.label, "Final")
        XCTAssertEqual(controller.outlineRows.first?.outline.label, "Final")

        controller.deleteOutline(row)

        XCTAssertEqual(document.outlineRoot?.numberOfChildren ?? 0, 0)
        XCTAssertTrue(controller.outlineRows.isEmpty)
    }

    func testRenameAndDeleteOutlineCanUndoAndRedo() throws {
        let controller = StudioController()
        let document = makeSolidColorDocument(colors: [.red])
        controller.document = document
        controller.addOutline(title: "Draft")
        let row = try XCTUnwrap(controller.outlineRows.first)

        controller.renameOutline(row, title: "Final")

        XCTAssertEqual(row.outline.label, "Final")

        controller.undoLastEdit()

        XCTAssertEqual(row.outline.label, "Draft")

        controller.redoLastEdit()

        XCTAssertEqual(row.outline.label, "Final")

        controller.deleteOutline(row)

        XCTAssertEqual(document.outlineRoot?.numberOfChildren ?? 0, 0)

        controller.undoLastEdit()

        XCTAssertEqual(document.outlineRoot?.numberOfChildren, 1)
        XCTAssertEqual(document.outlineRoot?.child(at: 0)?.label, "Final")

        controller.redoLastEdit()

        XCTAssertEqual(document.outlineRoot?.numberOfChildren ?? 0, 0)
    }

    func testMetadataDraftReadsEditableDocumentAttributes() {
        let controller = StudioController()
        let document = makeSolidColorDocument(colors: [.red])
        document.documentAttributes = [
            PDFDocumentAttribute.titleAttribute: "Quarterly Packet",
            "Author": "Ops Team",
            PDFDocumentAttribute.keywordsAttribute: ["finance", "review"],
        ]
        controller.document = document

        let draft = controller.metadataDraft()

        XCTAssertEqual(draft.title, "Quarterly Packet")
        XCTAssertEqual(draft.author, "Ops Team")
        XCTAssertEqual(draft.keywords, "finance, review")
    }

    func testApplyMetadataTrimsAndRemovesEmptyEditableFields() {
        let controller = StudioController()
        let document = makeSolidColorDocument(colors: [.red])
        document.documentAttributes = [
            PDFDocumentAttribute.titleAttribute: "Old",
            PDFDocumentAttribute.authorAttribute: "Internal",
            PDFDocumentAttribute.creationDateAttribute: Date(timeIntervalSince1970: 0),
        ]
        controller.document = document

        controller.applyMetadata(DocumentMetadataDraft(
            title: "  Final Packet  ",
            author: "   ",
            subject: " Ready ",
            keywords: " alpha, , beta ",
            creator: "",
            producer: "PDFQuickFix"
        ))

        let attributes = document.documentAttributes ?? [:]
        XCTAssertEqual(attributes[PDFDocumentAttribute.titleAttribute] as? String, "Final Packet")
        XCTAssertNil(attributes[PDFDocumentAttribute.authorAttribute])
        XCTAssertEqual(attributes[PDFDocumentAttribute.subjectAttribute] as? String, "Ready")
        XCTAssertEqual(attributes[PDFDocumentAttribute.keywordsAttribute] as? [String], ["alpha", "beta"])
        XCTAssertEqual(attributes[PDFDocumentAttribute.producerAttribute] as? String, "PDFQuickFix")
        XCTAssertNotNil(attributes[PDFDocumentAttribute.creationDateAttribute])
    }

    func testClearMetadataRemovesDocumentAttributes() {
        let controller = StudioController()
        let document = makeSolidColorDocument(colors: [.red])
        document.documentAttributes = [PDFDocumentAttribute.titleAttribute: "Secret"]
        controller.document = document

        controller.clearMetadata()

        XCTAssertTrue(document.documentAttributes?.isEmpty ?? true)
    }

    func testMetadataEditsCanUndoAndRedo() {
        let controller = StudioController()
        let document = makeSolidColorDocument(colors: [.red])
        document.documentAttributes = [
            PDFDocumentAttribute.titleAttribute: "Draft",
            PDFDocumentAttribute.authorAttribute: "Ops",
        ]
        controller.document = document

        controller.applyMetadata(DocumentMetadataDraft(title: "Final",
                                                       author: "",
                                                       subject: "Review",
                                                       keywords: "",
                                                       creator: "",
                                                       producer: "PDFQuickFix"))

        XCTAssertEqual(document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "Final")
        XCTAssertNil(document.documentAttributes?[PDFDocumentAttribute.authorAttribute])

        controller.undoLastEdit()

        XCTAssertEqual(document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "Draft")
        XCTAssertEqual(document.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String, "Ops")

        controller.redoLastEdit()

        XCTAssertEqual(document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "Final")
        XCTAssertNil(document.documentAttributes?[PDFDocumentAttribute.authorAttribute])
    }

    func testClearMetadataCanUndoAndRedo() {
        let controller = StudioController()
        let document = makeSolidColorDocument(colors: [.red])
        document.documentAttributes = [PDFDocumentAttribute.titleAttribute: "Secret"]
        controller.document = document

        controller.clearMetadata()

        XCTAssertTrue(document.documentAttributes?.isEmpty ?? true)

        controller.undoLastEdit()

        XCTAssertEqual(document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "Secret")

        controller.redoLastEdit()

        XCTAssertTrue(document.documentAttributes?.isEmpty ?? true)
    }

    private func makeSolidColorImageFile(color: NSColor, size: CGSize = CGSize(width: 80, height: 80)) throws -> URL {
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()

        let data = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString).png")
        try png.write(to: url)
        return url
    }

    private func countAnnotations(containing text: String, in document: PDFDocument) -> Int {
        (0 ..< document.pageCount).reduce(0) { count, index in
            guard let page = document.page(at: index) else { return count }
            return count + page.annotations.filter { $0.contents == text }.count
        }
    }

    private func realAnnotationCount(on page: PDFPage) -> Int {
        page.annotations.filter { !($0 is SelectionAnnotation) }.count
    }

    private func makeTextBackedDocument(text: String) throws -> PDFDocument {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")

        var mediaBox = CGRect(x: 0, y: 0, width: 320, height: 240)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "StudioControllerTests", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Unable to create PDF context",
            ])
        }

        context.beginPDFPage(nil)
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        NSColor.white.setFill()
        mediaBox.fill()
        NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 18),
                .foregroundColor: NSColor.black,
            ]
        ).draw(in: CGRect(x: 24, y: 120, width: 272, height: 40))
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()

        defer { try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(PDFDocument(data: data))
    }

    private func assertPageColors(_ document: PDFDocument, _ expectedColors: [NSColor], file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(document.pageCount, expectedColors.count, file: file, line: line)
        for (index, expectedColor) in expectedColors.enumerated() {
            let page = try XCTUnwrap(document.page(at: index), file: file, line: line)
            let rendered = try XCTUnwrap(TestPDFRenderer.render(page, size: CGSize(width: 80, height: 80)), file: file, line: line)
            let sampled = try XCTUnwrap(rendered.color(at: CGPoint(x: 40, y: 40)), file: file, line: line)
            XCTAssertTrue(sampled.isApproximately(expectedColor), "Unexpected color at page index \(index)", file: file, line: line)
        }
    }
}

private final class ThumbnailSnapshotTrackingDocument: PDFDocument {
    private let trackingLock = NSLock()
    private var callCount = 0
    private var wasCalledOnMainThread = false
    var dataRepresentationCallCount: Int {
        trackingLock.withLock { callCount }
    }

    var dataRepresentationWasCalledOnMainThread: Bool {
        trackingLock.withLock { wasCalledOnMainThread }
    }

    override func dataRepresentation() -> Data? {
        trackingLock.withLock {
            callCount += 1
            wasCalledOnMainThread = wasCalledOnMainThread || Thread.isMainThread
        }
        return super.dataRepresentation()
    }
}

private extension NSColor {
    func isApproximately(_ other: NSColor, tolerance: CGFloat = 0.05) -> Bool {
        let lhs = usingColorSpace(.sRGB) ?? self
        let rhs = other.usingColorSpace(.sRGB) ?? other
        return abs(lhs.redComponent - rhs.redComponent) <= tolerance &&
            abs(lhs.greenComponent - rhs.greenComponent) <= tolerance &&
            abs(lhs.blueComponent - rhs.blueComponent) <= tolerance
    }
}
