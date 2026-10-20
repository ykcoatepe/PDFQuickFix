import AppKit
import CoreGraphics
import PDFKit
@testable import PDFQuickFix
import PDFQuickFixKit
import XCTest

final class PDFDocumentSerializerTests: XCTestCase {
    func testRemoteFileSpecificationLargeIntegerMismatchCannotReplaceDestination() throws {
        let original = rawRemotePDF(fileExtension: "/Extension 9007199254740992")
        let source = try XCTUnwrap(SerializationStubDocument(data: original))
        let baseline = try PDFDocumentSerializer.remoteBaseline(for: source)
        source.result = original
        XCTAssertNoThrow(try PDFDocumentSerializer.data(from: source, remoteBaseline: baseline))
        source.result = rawRemotePDF(fileExtension: "/Extension 9007199254740993")
        let destination = temporaryURL()
        let sentinel = Data("Original file specification".utf8)
        try sentinel.write(to: destination)
        defer { try? FileManager.default.removeItem(at: destination) }
        XCTAssertThrowsError(try PDFDocumentSerializer.write(source, to: destination, remoteBaseline: baseline))
        XCTAssertEqual(try Data(contentsOf: destination), sentinel)
    }

    func testRemoteFileSpecificationInvalidUTF8AndNonASCIINamesAndKeysFailClosed() throws {
        for extensionValue in ["/Extension /X#FF", "/X#FF true", "/X#FF true /X#FE false",
                               "/Extension /Caf#C3#A9", "/Extension /Cafe#CC#81",
                               "/Caf#C3#A9 true", "/Cafe#CC#81 false"] {
            let source = try reload(rawRemotePDF(fileExtension: extensionValue))
            XCTAssertThrowsError(try PDFDocumentSerializer.remoteBaseline(for: source))
        }
    }

    func testRemoteActionWindowMismatchAndUnsupportedChainedActionsFailClosed() throws {
        let source = try XCTUnwrap(SerializationStubDocument(data: rawRemotePDF(actionExtension: "/NewWindow true")))
        let baseline = try PDFDocumentSerializer.remoteBaseline(for: source)
        source.result = rawRemotePDF(actionExtension: "/NewWindow false")
        XCTAssertThrowsError(try PDFDocumentSerializer.data(from: source, remoteBaseline: baseline))
        for extra in ["/Next << /S /URI /URI (https://example.com) >>", "/Unexpected true"] {
            XCTAssertThrowsError(try PDFDocumentSerializer.remoteBaseline(for: reload(rawRemotePDF(actionExtension: extra))))
        }
    }

    func testImplicitOwnerAccessCannotAcceptWidenedUnderlyingUserPermissions() throws {
        for ownerPassword in ["owner-pass", "user-pass"] {
            let backend = try loadedDocument(withOutline: false)
            let options: [AnyHashable: Any] = [
                PDFDocumentWriteOption.userPasswordOption: "user-pass",
                PDFDocumentWriteOption.ownerPasswordOption: ownerPassword,
                PDFDocumentWriteOption.accessPermissionsOption: NSNumber(value: 2),
            ]
            let original = try PDFDocumentSerializer.data(from: backend, options: options)
            var widened = options
            widened[PDFDocumentWriteOption.accessPermissionsOption] = NSNumber(value: 255)
            let source = try XCTUnwrap(SerializationStubDocument(data: original))
            XCTAssertTrue(source.unlock(withPassword: ownerPassword))
            XCTAssertEqual(source.permissionsStatus, .owner)
            source.result = try PDFDocumentSerializer.data(from: backend, options: widened)
            let destination = temporaryURL()
            try original.write(to: destination)
            defer { try? FileManager.default.removeItem(at: destination) }

            XCTAssertThrowsError(try PDFDocumentSerializer.write(source, to: destination, verificationPassword: ownerPassword)) { error in
                guard case PDFDocumentSerializationError.ownerPermissionsVerificationRequired = error else {
                    return XCTFail("Expected explicit owner permission boundary, received \(error)")
                }
                XCTAssertTrue(error.localizedDescription.contains("Export Encrypted Copy"))
            }
            XCTAssertEqual(try Data(contentsOf: destination), original)
        }
    }

    func testExplicitEncryptionRejectsWrongOwnerCredentialAndWidenedPermissions() throws {
        let source = try XCTUnwrap(SerializationStubDocument(data: XCTUnwrap(loadedDocument(withOutline: false).dataRepresentation())))
        let options: [AnyHashable: Any] = [
            PDFDocumentWriteOption.userPasswordOption: "user-pass",
            PDFDocumentWriteOption.ownerPasswordOption: "owner-pass",
            PDFDocumentWriteOption.accessPermissionsOption: NSNumber(value: 2),
            kCGPDFContextEncryptionKeyLength as String: 128,
        ]
        let backend = try loadedDocument(withOutline: false)
        for changedKey in [PDFDocumentWriteOption.ownerPasswordOption, PDFDocumentWriteOption.accessPermissionsOption] {
            var badOptions = options
            badOptions[changedKey] = changedKey == .ownerPasswordOption ? "wrong-owner" : NSNumber(value: 255)
            source.result = try XCTUnwrap(backend.dataRepresentation(options: badOptions))
            let destination = temporaryURL()
            let sentinel = Data("Original protected export".utf8)
            try sentinel.write(to: destination)
            defer { try? FileManager.default.removeItem(at: destination) }
            XCTAssertThrowsError(try PDFDocumentSerializer.write(source, to: destination, options: options))
            XCTAssertEqual(try Data(contentsOf: destination), sentinel)
        }
    }

    func testFlatteningRemoteBookmarksFailsBeforeProducingLossyOutput() throws {
        let source = try reload(rawRemotePDF())

        XCTAssertThrowsError(try PDFOps.flattenedData(document: source)) { error in
            XCTAssertTrue(error.localizedDescription.contains("linked remote bookmarks"))
            XCTAssertTrue(error.localizedDescription.contains("destination was not changed"))
        }
        XCTAssertEqual(source.outlineRoot?.numberOfChildren, 1)
    }

    func testValidRawRemoteBookmarkPreservesFileSpecificationAndAllXYZOperands() throws {
        enableSyntheticSerializerDiagnostics()
        defer { disableSyntheticSerializerDiagnostics() }
        let sourceURL = temporaryURL()
        try rawRemotePDF().write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let source = try XCTUnwrap(PDFDocument(url: sourceURL))
        let baseline = try PDFDocumentSerializer.remoteBaseline(for: source)
        let output = try syntheticVerifiedWrite(source, baseline: baseline)
        let reloaded = try reload(output)
        let action = try firstRawRemoteAction(in: reloaded)
        var operands: CGPDFArrayRef?
        XCTAssertTrue(CGPDFDictionaryGetArray(action, "D", &operands))
        let destination = try XCTUnwrap(operands)
        XCTAssertEqual(CGPDFArrayGetCount(destination), 5)
        var zoom: CGPDFReal = 0
        XCTAssertTrue(CGPDFArrayGetNumber(destination, 4, &zoom))
        XCTAssertEqual(zoom, 1.25)
        var fileSpec: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(action, "F", &fileSpec))
        var description: CGPDFStringRef?
        XCTAssertTrue(CGPDFDictionaryGetString(try XCTUnwrap(fileSpec), "Desc", &description))
        XCTAssertEqual(CGPDFStringCopyTextString(try XCTUnwrap(description)) as String?, "Remote document")
    }

    func testChangedRemoteZoomOrFileSpecificationCannotReplaceDestination() throws {
        for replacement in [rawRemotePDF(zoom: "2.5"), rawRemotePDF(description: "Changed description")] {
            let source = try XCTUnwrap(SerializationStubDocument(data: rawRemotePDF()))
            let baseline = try PDFDocumentSerializer.remoteBaseline(for: source)
            source.result = replacement
            let destination = temporaryURL()
            let sentinel = Data("Original bytes".utf8)
            try sentinel.write(to: destination)
            defer { try? FileManager.default.removeItem(at: destination) }

            XCTAssertThrowsError(try PDFDocumentSerializer.write(source, to: destination, remoteBaseline: baseline))
            XCTAssertEqual(try Data(contentsOf: destination), sentinel)
        }
    }

    func testMalformedRemoteActionsFailWithoutSwiftBridgeTrap() throws {
        for data in [rawRemotePDF(missingFile: true),
                     rawRemotePDF(invalidCoordinates: true), rawRemotePDF(outlineCycle: true)] {
            let document = try reload(data)
            XCTAssertThrowsError(try PDFDocumentSerializer.remoteBaseline(for: document))
        }
    }

    func testDuplicateRemoteLabelsWithDifferentRawPagesRetainFullOrderedTargets() throws {
        enableSyntheticSerializerDiagnostics()
        defer { disableSyntheticSerializerDiagnostics() }
        let source = try reload(rawRemotePDF(ambiguousDuplicate: true))
        XCTAssertThrowsError(try PDFDocumentSerializer.data(from: source), "A bare caller must capture context before edits")
        let baseline = try PDFDocumentSerializer.remoteBaseline(for: source)
        let output = try syntheticVerifiedWrite(source, baseline: baseline)
        let reloaded = try reload(output)
        XCTAssertEqual(reloaded.outlineRoot?.numberOfChildren, 2)
        let first = try firstRawRemoteAction(in: reloaded)
        var destination: CGPDFArrayRef?
        XCTAssertTrue(CGPDFDictionaryGetArray(first, "D", &destination))
        var page: CGPDFInteger = -1
        XCTAssertTrue(CGPDFArrayGetInteger(try XCTUnwrap(destination), 0, &page))
        XCTAssertEqual(page, 0)
        let catalog = try XCTUnwrap(reloaded.documentRef?.catalog)
        var outlines: CGPDFDictionaryRef?
        var secondNode: CGPDFDictionaryRef?
        var secondAction: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(catalog, "Outlines", &outlines))
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(outlines), "Last", &secondNode))
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(secondNode), "A", &secondAction))
        XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(secondAction), "D", &destination))
        XCTAssertTrue(CGPDFArrayGetInteger(try XCTUnwrap(destination), 0, &page))
        XCTAssertEqual(page, 7, "The SDK's public GoToR pageIndex may report zero for both targets")
    }

    func testRemoteBaselineRejectsTargetOrderDeletionAndWrongDocument() throws {
        for change in 0 ..< 4 {
            let source = try reload(rawRemotePDF(ambiguousDuplicate: true))
            let baseline = try PDFDocumentSerializer.remoteBaseline(for: source)
            let root = try XCTUnwrap(source.outlineRoot)
            let first = try XCTUnwrap(root.child(at: 0))
            switch change {
            case 0:
                let action = try XCTUnwrap(first.action as? PDFActionRemoteGoTo)
                action.pageIndex = 9
            case 1:
                let last = try XCTUnwrap(root.child(at: 1))
                last.removeFromParent()
                root.insertChild(last, at: 0)
            case 2:
                first.removeFromParent()
            default:
                let another = try reload(rawRemotePDF(ambiguousDuplicate: true))
                XCTAssertThrowsError(try PDFDocumentSerializer.data(from: another, remoteBaseline: baseline))
                continue
            }
            XCTAssertThrowsError(try PDFDocumentSerializer.data(from: source, remoteBaseline: baseline))
        }
    }

    func testLocalEditCanBeAcceptedOnlyWithUnchangedCompleteRemoteSequence() throws {
        let source = try XCTUnwrap(SerializationStubDocument(data: rawRemotePDF()))
        let baseline = try PDFDocumentSerializer.remoteBaseline(for: source)
        let local = chapter(in: source, title: "Local addition", point: CGPoint(x: 20, y: 40))
        try XCTUnwrap(source.outlineRoot).insertChild(local, at: 1)
        // Model a backend that preserves raw GoToR fields. The actual SDK's
        // ability to produce these bytes is a separate real-document gate.
        source.result = rawRemotePDF(withLocalAddition: true)
        let output = try PDFDocumentSerializer.data(from: source, remoteBaseline: baseline)
        let reloaded = try reload(output)
        XCTAssertEqual(reloaded.outlineRoot?.child(at: 1)?.label, "Local addition")

        source.result = rawRemotePDF(zoom: "9", withLocalAddition: true)
        XCTAssertThrowsError(try PDFDocumentSerializer.data(from: source, remoteBaseline: baseline))
    }

    func testExplicitOutlineRemovalCanClearRemoteTargetsAndRestoreSourceRoot() throws {
        let source = try reload(rawRemotePDF())
        let originalRoot = source.outlineRoot
        let output = try PDFDocumentSerializer.data(from: source, removingOutline: true)
        XCTAssertEqual(try reload(output).outlineRoot?.numberOfChildren ?? 0, 0)
        XCTAssertTrue(source.outlineRoot === originalRoot)
    }

    func testEncryptedLockRequirementAndPermissionsCannotBeWeakened() throws {
        let plain = try loadedDocument(withOutline: false)
        let sourceBytes = try PDFDocumentSerializer.data(from: plain, options: [
            PDFDocumentWriteOption.userPasswordOption: "user-pass",
            PDFDocumentWriteOption.ownerPasswordOption: "owner-pass",
            PDFDocumentWriteOption.accessPermissionsOption: NSNumber(value: 2),
        ])
        let ownerOnly = try PDFDocumentSerializer.data(from: plain, options: [
            PDFDocumentWriteOption.ownerPasswordOption: "owner-pass",
        ])
        let unrestricted = try PDFDocumentSerializer.data(from: plain, options: [
            PDFDocumentWriteOption.userPasswordOption: "user-pass",
            PDFDocumentWriteOption.ownerPasswordOption: "owner-pass",
        ])
        for unsafeCandidate in [ownerOnly, unrestricted] {
            let source = try XCTUnwrap(SerializationStubDocument(data: sourceBytes))
            XCTAssertTrue(source.unlock(withPassword: "user-pass"))
            source.result = unsafeCandidate
            let destination = temporaryURL()
            try sourceBytes.write(to: destination)
            defer { try? FileManager.default.removeItem(at: destination) }

            XCTAssertThrowsError(try PDFDocumentSerializer.write(source, to: destination,
                                                                 verificationPassword: "user-pass"))
            XCTAssertEqual(try Data(contentsOf: destination), sourceBytes)
        }
        let ownerOnlySource = try reload(ownerOnly)
        XCTAssertTrue(ownerOnlySource.isEncrypted)
        XCTAssertFalse(ownerOnlySource.isLocked)
        let preserved = try reload(try PDFDocumentSerializer.data(from: ownerOnlySource, requiresUserPassword: false))
        XCTAssertTrue(preserved.isEncrypted)
        XCTAssertFalse(preserved.isLocked)
    }

    func testRepairedCopyValidatesBeforeAtomicReplacementAndRetainsSourceOnFailure() throws {
        let source = temporaryURL()
        let destination = temporaryURL()
        let bytes = try XCTUnwrap(loadedDocument(withOutline: true).dataRepresentation())
        try bytes.write(to: source)
        let sentinel = Data("Original target".utf8)
        try sentinel.write(to: destination)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        try PDFDocumentSerializer.copyValidatedPDF(from: source, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertEqual(try Data(contentsOf: source), bytes)

        try sentinel.write(to: destination)
        try Data("Not a PDF".utf8).write(to: source)
        XCTAssertThrowsError(try PDFDocumentSerializer.copyValidatedPDF(from: source, to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), sentinel)

        try bytes.write(to: source)
        let directory = temporaryURL()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = directory.appendingPathComponent("existing")
        try sentinel.write(to: existing)
        XCTAssertThrowsError(try PDFDocumentSerializer.copyValidatedPDF(from: source, to: directory))
        XCTAssertEqual(try Data(contentsOf: existing), sentinel)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testLoadedDocumentPersistsOrderedNestedDestinationsAndURLActions() throws {
        let document = try loadedDocument(withOutline: true)
        let root = try XCTUnwrap(document.outlineRoot)
        root.child(at: 0)?.label = "Renamed"
        root.child(at: 1)?.removeFromParent()
        let nested = chapter(in: document, title: "Nested", point: CGPoint(x: 31, y: 47))
        root.child(at: 0)?.insertChild(nested, at: 0)
        let link = PDFOutline()
        link.label = "Source URL"
        link.action = PDFActionURL(url: try XCTUnwrap(URL(string: "https://example.com/bookmark")))
        root.insertChild(link, at: 1)

        let reloaded = try reload(try PDFDocumentSerializer.data(from: document))
        let reloadedRoot = try XCTUnwrap(reloaded.outlineRoot)
        XCTAssertEqual(reloadedRoot.numberOfChildren, 2)
        XCTAssertEqual(reloadedRoot.child(at: 0)?.label, "Renamed")
        let reloadedNested = try XCTUnwrap(reloadedRoot.child(at: 0)?.child(at: 0))
        XCTAssertEqual(reloadedNested.label, "Nested")
        XCTAssertEqual(reloadedNested.destination?.point, CGPoint(x: 31, y: 47))
        XCTAssertTrue(reloadedNested.destination?.page === reloaded.page(at: 0))
        XCTAssertEqual((reloadedRoot.child(at: 1)?.action as? PDFActionURL)?.url,
                       URL(string: "https://example.com/bookmark"))
        XCTAssertTrue(document.outlineRoot === root)
    }

    func testNilAndEmptyRootsRemoveOriginallyPersistedOutlineAndRestoreIdentity() throws {
        for useNil in [false, true] {
            let document = try loadedDocument(withOutline: true)
            let emptyRoot = PDFOutline()
            document.outlineRoot = useNil ? nil : emptyRoot
            // PDFKit may immediately rehydrate the original root after its nil
            // setter. Express removal explicitly rather than infer lost intent.
            let observedRoot = document.outlineRoot

            let reloaded = try reload(try PDFDocumentSerializer.data(from: document, removingOutline: useNil))

            XCTAssertEqual(reloaded.outlineRoot?.numberOfChildren ?? 0, 0)
            if useNil { XCTAssertTrue(document.outlineRoot === observedRoot) }
            else { XCTAssertTrue(document.outlineRoot === emptyRoot) }
        }
    }

    func testDefaultEncryptionAndRestrictedPasswordsSurviveLoadedOutlineEdit() throws {
        enableSyntheticSerializerDiagnostics()
        defer { disableSyntheticSerializerDiagnostics() }
        for keyLength in [40, 128] {
            print("[serializer-test-context] encryption.\(keyLength == 40 ? "legacy" : "modern").initial-export")
            let source = try loadedDocument(withOutline: false)
            let options: [AnyHashable: Any] = [
                PDFDocumentWriteOption.userPasswordOption: "user-pass",
                PDFDocumentWriteOption.ownerPasswordOption: "owner-pass",
                PDFDocumentWriteOption.accessPermissionsOption: NSNumber(value: 2),
                kCGPDFContextEncryptionKeyLength as String: keyLength,
            ]
            let encryptedBytes = try syntheticVerifiedWrite(source, options: options)
            let encryptionHeader = String(data: encryptedBytes, encoding: .isoLatin1) ?? ""
            let encryptionObject = try XCTUnwrap(encryptionHeader.components(separatedBy: "endobj").first {
                $0.range(of: #"/Filter\s*/Standard\b"#, options: .regularExpression) != nil
            })
            XCTAssertNotNil(encryptionObject.range(of: "/Length\\s+\(keyLength)\\b", options: .regularExpression))
            let encrypted = try reload(encryptedBytes)
            XCTAssertTrue(encrypted.isLocked)
            XCTAssertFalse(encrypted.unlock(withPassword: "wrong"))
            XCTAssertTrue(encrypted.unlock(withPassword: "user-pass"))
            XCTAssertFalse(encrypted.allowsCopying)
            // Accept a default rewrite only if the original password still works.
            // This SDK also fails to preserve legacy keys on an unchanged PDF.
            do {
                print("[serializer-test-context] encryption.ordinary-save")
                let unchanged = try reload(try PDFDocumentSerializer.data(from: encrypted, verificationPassword: "user-pass"))
                XCTAssertTrue(unchanged.unlock(withPassword: "user-pass"))
            } catch PDFDocumentSerializationError.validationFailed {
                XCTAssertEqual(keyLength, 40, "Modern encrypted output must remain verifiable")
            }
            let root = PDFOutline()
            root.insertChild(chapter(in: encrypted, title: "Restricted chapter"), at: 0)
            encrypted.outlineRoot = root

            if keyLength == 40 {
                // This PDFKit runtime cannot preserve legacy keys when a full
                // outline rewrite is needed. Refuse to replace the original.
                let destination = temporaryURL()
                try encryptedBytes.write(to: destination)
                defer { try? FileManager.default.removeItem(at: destination) }
                do {
                    print("[serializer-test-context] encryption.legacy-outline-save")
                    try PDFDocumentSerializer.write(encrypted, to: destination, verificationPassword: "user-pass")
                    let saved = try reload(Data(contentsOf: destination))
                    XCTAssertTrue(saved.unlock(withPassword: "user-pass"))
                    XCTAssertEqual(saved.outlineRoot?.child(at: 0)?.label, "Restricted chapter")
                } catch PDFDocumentSerializationError.validationFailed {
                    XCTAssertEqual(try Data(contentsOf: destination), encryptedBytes)
                }
            }
            // Explicit encryption is a separate operation with caller-chosen keys.
            print("[serializer-test-context] encryption.explicit-outline-export")
            let output = try syntheticVerifiedWrite(encrypted, options: options)
            let reloaded = try reload(output)
            XCTAssertTrue(reloaded.isEncrypted)
            XCTAssertTrue(reloaded.isLocked)
            XCTAssertFalse(reloaded.unlock(withPassword: "wrong"))
            XCTAssertTrue(reloaded.unlock(withPassword: "user-pass"))
            XCTAssertFalse(reloaded.allowsCopying)
            XCTAssertTrue(reloaded.allowsPrinting)
            XCTAssertEqual(reloaded.outlineRoot?.child(at: 0)?.label, "Restricted chapter")
            let ownerCopy = try reload(output)
            XCTAssertTrue(ownerCopy.unlock(withPassword: "owner-pass"))
            XCTAssertTrue(ownerCopy.allowsCopying)
            XCTAssertTrue(encrypted.outlineRoot === root)
        }
    }

    func testPreservesTextMetadataPageGeometryFormWidgetsNotesAndLinks() throws {
        let document = try loadedDocument(withOutline: false)
        document.documentAttributes = [PDFDocumentAttribute.authorAttribute: "Synthetic author"]
        let page = try XCTUnwrap(document.page(at: 0))
        page.rotation = 90
        page.setBounds(CGRect(x: 4, y: 6, width: 280, height: 280), for: .cropBox)
        let note = PDFAnnotation(bounds: CGRect(x: 10, y: 20, width: 25, height: 25), forType: .text, withProperties: nil)
        note.contents = "Persistent note"
        page.addAnnotation(note)
        let link = PDFAnnotation(bounds: CGRect(x: 50, y: 20, width: 25, height: 25), forType: .link, withProperties: nil)
        link.action = PDFActionURL(url: try XCTUnwrap(URL(string: "https://example.com/link")))
        page.addAnnotation(link)
        let textField = widget(named: "Text field", in: page, type: .text)
        textField.widgetStringValue = "Field value"
        let checkBox = widget(named: "Checkbox", in: page, type: .button)
        checkBox.widgetControlType = .checkBoxControl
        checkBox.buttonWidgetState = .onState
        let radio = widget(named: "Radio", in: page, type: .button)
        radio.widgetControlType = .radioButtonControl
        radio.buttonWidgetState = .onState
        let root = PDFOutline()
        root.insertChild(chapter(in: document, title: "Chapter"), at: 0)
        document.outlineRoot = root
        XCTAssertTrue((document.string ?? "").contains("Searchable serializer text"), "Fixture must retain searchable text")

        let reloaded = try reload(try PDFDocumentSerializer.data(from: document))
        let resultPage = try XCTUnwrap(reloaded.page(at: 0))
        XCTAssertTrue((reloaded.string ?? "").contains("Searchable serializer text"))
        XCTAssertEqual(reloaded.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String, "Synthetic author")
        XCTAssertEqual(resultPage.rotation, 90)
        XCTAssertEqual(resultPage.bounds(for: .cropBox), page.bounds(for: .cropBox))
        XCTAssertEqual(resultPage.bounds(for: .mediaBox), page.bounds(for: .mediaBox))
        XCTAssertTrue(resultPage.annotations.contains { $0.contents == "Persistent note" })
        XCTAssertTrue(resultPage.annotations.contains {
            ($0.action as? PDFActionURL)?.url == URL(string: "https://example.com/link")
        })
        XCTAssertEqual(resultPage.annotations.first { $0.fieldName == "Text field" }?.widgetStringValue, "Field value")
        for original in [checkBox, radio] {
            let result = try XCTUnwrap(resultPage.annotations.first { $0.fieldName == original.fieldName })
            XCTAssertEqual(result.widgetControlType, original.widgetControlType)
            XCTAssertEqual(result.buttonWidgetState, original.buttonWidgetState)
        }
    }

    func testCandidateMismatchLeavesDestinationUnchangedAndRestoresRoot() throws {
        let candidate = try loadedDocument(withOutline: true)
        let staleBytes = try XCTUnwrap(candidate.dataRepresentation())
        let document = SerializationStubDocument()
        document.insert(PDFPage(), at: 0)
        let root = PDFOutline()
        root.insertChild(chapter(in: document, title: "Original", point: CGPoint(x: 99, y: 21)), at: 0)
        root.insertChild(chapter(in: document, title: "Second"), at: 1)
        document.outlineRoot = root
        document.result = staleBytes
        let destination = temporaryURL()
        let sentinel = Data("Original destination bytes".utf8)
        try sentinel.write(to: destination)
        defer { try? FileManager.default.removeItem(at: destination) }

        XCTAssertThrowsError(try PDFDocumentSerializer.write(document, to: destination))

        XCTAssertEqual(try Data(contentsOf: destination), sentinel)
        XCTAssertTrue(document.outlineRoot === root)
    }

    func testFailedSerializationRestoresNilRootAndDoesNotReplaceDestination() throws {
        let document = SerializationStubDocument()
        document.insert(PDFPage(), at: 0)
        let destination = temporaryURL()
        let sentinel = Data("Original destination bytes".utf8)
        try sentinel.write(to: destination)
        defer { try? FileManager.default.removeItem(at: destination) }

        XCTAssertThrowsError(try PDFDocumentSerializer.write(document, to: destination))

        XCTAssertNil(document.outlineRoot)
        XCTAssertEqual(try Data(contentsOf: destination), sentinel)
    }

    func testActualReplacementFailurePreservesExistingDirectoryContents() throws {
        let destination = temporaryURL()
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: destination) }
        let sentinelURL = destination.appendingPathComponent("existing-file")
        let sentinel = Data("Keep existing contents".utf8)
        try sentinel.write(to: sentinelURL)
        let document = try loadedDocument(withOutline: true)
        let root = document.outlineRoot

        XCTAssertThrowsError(try PDFDocumentSerializer.write(document, to: destination))

        XCTAssertEqual(try Data(contentsOf: sentinelURL), sentinel)
        XCTAssertTrue(document.outlineRoot === root)
    }

    func testUnsupportedAndOutOfDocumentActionsAreRejectedBeforeWriting() throws {
        for invalidDestination in [false, true] {
            let document = try loadedDocument(withOutline: false)
            let root = PDFOutline()
            let child = PDFOutline()
            child.label = "Cannot verify"
            if invalidDestination {
                child.destination = PDFDestination(page: PDFPage(), at: .zero)
            } else {
                child.action = PDFActionNamed(name: .nextPage)
            }
            root.insertChild(child, at: 0)
            document.outlineRoot = root
            let destination = temporaryURL()
            let sentinel = Data("Original destination bytes".utf8)
            try sentinel.write(to: destination)
            defer { try? FileManager.default.removeItem(at: destination) }

            XCTAssertThrowsError(try PDFDocumentSerializer.write(document, to: destination))
            XCTAssertEqual(try Data(contentsOf: destination), sentinel)
            XCTAssertTrue(document.outlineRoot === root)
        }
    }

    func testUnexpectedUnencryptedCandidateIsRejected() throws {
        let source = try loadedDocument(withOutline: false)
        let document = SerializationStubDocument()
        document.insert(PDFPage(), at: 0)
        document.result = try XCTUnwrap(source.dataRepresentation())

        XCTAssertThrowsError(try PDFDocumentSerializer.data(from: document, options: [
            PDFDocumentWriteOption.userPasswordOption: "requested-pass",
            PDFDocumentWriteOption.ownerPasswordOption: "owner-pass",
        ]))
        XCTAssertNil(document.outlineRoot)
    }

    /// Preserve the success assertions while proving rejected native candidates
    /// cannot replace an existing destination or mutate the source root.
    private func syntheticVerifiedWrite(_ document: PDFDocument, options: [AnyHashable: Any] = [:],
                                        baseline: PDFDocumentSerializer.RemoteOutlineBaseline? = nil) throws -> Data {
        let destination = temporaryURL()
        let sentinel = Data("Synthetic original destination".utf8)
        let root = document.outlineRoot
        try sentinel.write(to: destination)
        defer { try? FileManager.default.removeItem(at: destination) }
        do {
            try PDFDocumentSerializer.write(document, to: destination, options: options, remoteBaseline: baseline)
            XCTAssertTrue(document.outlineRoot === root)
            return try Data(contentsOf: destination)
        } catch {
            let destinationUnchanged = try Data(contentsOf: destination) == sentinel
            let sourceRootRestored = document.outlineRoot === root
            print("[serializer-test-context] rejected-candidate.destination-unchanged=\(destinationUnchanged).source-root-restored=\(sourceRootRestored)")
            XCTAssertTrue(destinationUnchanged)
            XCTAssertTrue(sourceRootRestored)
            throw error
        }
    }

    // Temporary P19 diagnostics are restricted to these known synthetic fixtures.
    private func enableSyntheticSerializerDiagnostics() {
        #if DEBUG
            setenv("PDFQUICKFIX_SYNTHETIC_SERIALIZER_DIAGNOSTICS", "1", 1)
        #endif
    }

    private func disableSyntheticSerializerDiagnostics() {
        #if DEBUG
            unsetenv("PDFQUICKFIX_SYNTHETIC_SERIALIZER_DIAGNOSTICS")
        #endif
    }

    private func loadedDocument(withOutline: Bool) throws -> PDFDocument {
        let view = NSTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        view.textContainerInset = CGSize(width: 20, height: 80)
        view.font = NSFont.systemFont(ofSize: 12)
        view.string = "Searchable serializer text"
        let original = try reload(view.dataWithPDF(inside: view.bounds))
        let fresh = PDFDocument()
        fresh.insert(try XCTUnwrap(original.page(at: 0)?.copy() as? PDFPage), at: 0)
        if withOutline {
            let root = PDFOutline()
            root.insertChild(chapter(in: fresh, title: "Original"), at: 0)
            root.insertChild(chapter(in: fresh, title: "Second"), at: 1)
            fresh.outlineRoot = root
        }
        return try reload(try XCTUnwrap(fresh.dataRepresentation()))
    }

    private func chapter(in document: PDFDocument, title: String, point: CGPoint = CGPoint(x: 12, y: 21)) -> PDFOutline {
        let child = PDFOutline()
        child.label = title
        child.action = PDFActionGoTo(destination: PDFDestination(page: document.page(at: 0)!, at: point))
        return child
    }

    private func widget(named name: String, in page: PDFPage, type: PDFAnnotationWidgetSubtype) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: CGRect(x: 20, y: 70, width: 100, height: 20), forType: .widget, withProperties: nil)
        annotation.widgetFieldType = type
        annotation.fieldName = name
        page.addAnnotation(annotation)
        return annotation
    }

    private func reload(_ data: Data) throws -> PDFDocument {
        try XCTUnwrap(PDFDocument(data: data))
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SerializerTests-\(UUID().uuidString)")
    }

    private func rawRemotePDF(zoom: String = "1.25", description: String = "Remote document",
                              missingFile: Bool = false, ambiguousDuplicate: Bool = false,
                              invalidCoordinates: Bool = false, outlineCycle: Bool = false,
                              withLocalAddition: Bool = false, fileExtension: String = "",
                              actionExtension: String = "") -> Data
    {
        let file = missingFile ? "" : "/F << /Type /Filespec /F (../other/linked.pdf) /UF (../other/linked.pdf) /Desc (\(description)) \(fileExtension) >>"
        let coordinates = invalidCoordinates ? "/Invalid" : "12"
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R /Outlines 4 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 300] /Resources << >> >>",
            "<< /Type /Outlines /First 5 0 R /Last \(ambiguousDuplicate || withLocalAddition ? 7 : 5) 0 R /Count \(ambiguousDuplicate || withLocalAddition ? 2 : 1) >>",
            "<< /Title (Remote) /Parent 4 0 R /A 6 0 R \(ambiguousDuplicate || withLocalAddition ? "/Next 7 0 R" : outlineCycle ? "/Next 5 0 R" : "") >>",
            "<< /S /GoToR \(file) /D [0 /XYZ \(coordinates) 34 \(zoom)] \(actionExtension) >>",
        ]
        if ambiguousDuplicate {
            objects.append("<< /Title (Remote) /Parent 4 0 R /Prev 5 0 R /A 8 0 R >>")
            objects.append("<< /S /GoToR \(file) /D [7 /XYZ 12 34 3.5] >>")
        } else if withLocalAddition {
            objects.append("<< /Title (Local addition) /Parent 4 0 R /Prev 5 0 R /Dest [3 0 R /XYZ 20 40 0] >>")
        }
        var data = Data("%PDF-1.4\n".utf8)
        var offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(data.count)
            data.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = data.count
        data.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() { data.append(Data(String(format: "%010d 00000 n \n", offset).utf8)) }
        data.append(Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return data
    }

    private func firstRawRemoteAction(in document: PDFDocument) throws -> CGPDFDictionaryRef {
        let catalog = try XCTUnwrap(document.documentRef?.catalog)
        var outlines: CGPDFDictionaryRef?
        var first: CGPDFDictionaryRef?
        var action: CGPDFDictionaryRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(catalog, "Outlines", &outlines))
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(outlines), "First", &first))
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(first), "A", &action))
        return try XCTUnwrap(action)
    }
}

private final class SerializationStubDocument: PDFDocument {
    var result: Data?

    override func dataRepresentation(options _: [AnyHashable: Any] = [:]) -> Data? {
        result
    }
}
