import Compression
import PDFKit
@testable import PDFQuickFix
@testable import PDFQuickFixKit
import XCTest

/// Sanitize for Sharing must not carry the source catalog into the output.
final class HiddenDataSanitizeTests: XCTestCase {
    private static let hiddenMarkers = [
        "XMPMARK", "ATTACHMARK", "ATTNAMEMARK", "JSMARK", "PIECEMARK", "OCGMARK", "PAGEAAMARK",
        "FAANNOTMARK", "FABODYMARK", "LINKJSMARK", "INFOMARK",
    ]

    func testScannerReportsEveryHiddenDataKindInFixture() throws {
        let found = try XCTUnwrap(PDFHiddenDataScanner.scan(data: Self.fixture(outline: true)))

        XCTAssertEqual(found, Set(PDFHiddenDataKind.allCases).subtracting([.pageThumbnail, .xfaForm]))
    }

    func testScannerReportsNothingForPlainDocument() throws {
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)

        XCTAssertEqual(PDFHiddenDataScanner.scan(data: try XCTUnwrap(document.dataRepresentation())), [])
        XCTAssertNil(PDFHiddenDataScanner.scan(data: Data("not a pdf".utf8)))
    }

    func testEditableProfilesRemoveHiddenDocumentData() throws {
        for profile in [SanitizeProfile.lightClean, .keepEditable] {
            for outline in [false, true] {
                let source = try XCTUnwrap(PDFDocument(data: Self.fixture(outline: outline)))
                let sanitized = try PDFDocumentSanitizer.sanitize(document: source, options: .from(profile: profile))
                let output = try PDFDocumentSerializer.data(from: sanitized, removingOutline: true)
                let context = "\(profile.rawValue) outline=\(outline)"

                XCTAssertEqual(PDFHiddenDataScanner.scan(data: output), [], context)
                let searchable = Self.searchableBytes(of: output)
                for marker in Self.hiddenMarkers + ["BOOKMARKTITLE"] {
                    XCTAssertNil(searchable.range(of: Data(marker.utf8)), "\(marker) survived \(context)")
                }

                let reloaded = try XCTUnwrap(PDFDocument(data: output))
                XCTAssertEqual(reloaded.pageCount, 1, context)
                XCTAssertTrue(reloaded.string?.contains("VISIBLEMARK") ?? false, context)
                let annotations = try XCTUnwrap(reloaded.page(at: 0)).annotations
                XCTAssertEqual(annotations.first { $0.fieldName == "fieldname" }?.widgetStringValue, "FIELDVALUE", context)
                XCTAssertFalse(annotations.contains { $0.type == "FileAttachment" }, context)
                XCTAssertNotNil(output.range(of: Data("/AcroForm".utf8)), "Form dictionary missing for \(context)")
                XCTAssertNil(output.range(of: Data("<?xpacket".utf8)), context)
            }
        }
    }

    /// The rewrite must not trade hidden data for broken documents.
    func testEditableProfilesKeepInternalLinksAndRadioSelection() throws {
        for profile in [SanitizeProfile.lightClean, .keepEditable] {
            let source = try XCTUnwrap(PDFDocument(data: Self.linkedFormFixture()))
            let sanitized = try PDFDocumentSanitizer.sanitize(document: source, options: .from(profile: profile))
            let output = try PDFDocumentSerializer.data(from: sanitized, removingOutline: true)
            let context = profile.rawValue

            XCTAssertEqual(PDFHiddenDataScanner.scan(data: output), [], context)
            XCTAssertNil(Self.searchableBytes(of: output).range(of: Data("XMPMARK".utf8)), context)
            let reloaded = try XCTUnwrap(PDFDocument(data: output))
            XCTAssertEqual(reloaded.pageCount, 2, context)
            let annotations = try XCTUnwrap(reloaded.page(at: 0)).annotations
            let link = try XCTUnwrap(annotations.first { $0.type == "Link" }, context)
            let target = try XCTUnwrap(link.destination?.page ?? (link.action as? PDFActionGoTo)?.destination.page, context)
            XCTAssertEqual(reloaded.index(for: target), 1, context)
            let radios = annotations.filter { $0.fieldName == "radio" }
            XCTAssertEqual(radios.map(\.buttonWidgetState), [.offState, .onState], context)
        }
    }

    func testEraserLeavesUnknownLayoutsAlone() {
        XCTAssertNil(PDFXMPEraser.erasingMetadataStreams(from: Data("%PDF-1.7\nnot a real file".utf8)))
    }

    func testPrivacyCleanRemovesHiddenDocumentData() throws {
        let source = try XCTUnwrap(PDFDocument(data: Self.fixture(outline: true)))
        let sanitized = try PDFDocumentSanitizer.sanitize(document: source, options: .from(profile: .privacyClean))
        let output = try PDFDocumentSerializer.data(from: sanitized, removingOutline: true)

        XCTAssertEqual(PDFHiddenDataScanner.scan(data: output), [])
        let searchable = Self.searchableBytes(of: output)
        for marker in Self.hiddenMarkers {
            XCTAssertNil(searchable.range(of: Data(marker.utf8)), "\(marker) survived privacyClean")
        }
    }

    func testSanitizeFailsClosedWhenHiddenDataRemains() throws {
        let source = try XCTUnwrap(PDFDocument(data: Self.fixture(outline: false)))
        // Nothing to change means no rewrite, so the source catalog would be returned as is.
        let options = PDFDocumentSanitizer.Options(rebuildMode: .never,
                                                   sanitizeAnnotations: false,
                                                   sanitizeOutline: false,
                                                   removeOutline: false,
                                                   scrubMetadata: false,
                                                   removeHiddenDocumentData: true)

        XCTAssertThrowsError(try PDFDocumentSanitizer.sanitize(document: source, options: options)) { error in
            guard case let PDFDocumentSanitizerError.hiddenDataRemains(kinds) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            // Which other kinds PDFKit's ordinary write keeps varies by macOS version.
            XCTAssertTrue(kinds.contains(.xmpMetadata))
        }
    }

    func testMetadataCleanedExportRemovesXMPAndKeepsBookmarks() throws {
        let source = try XCTUnwrap(PDFDocument(data: Self.fixture(outline: true)))

        let output = try PDFOps.metadataCleanedData(document: source)

        XCTAssertFalse(try XCTUnwrap(PDFHiddenDataScanner.scan(data: output)).contains(.xmpMetadata))
        let searchable = Self.searchableBytes(of: output)
        XCTAssertNil(searchable.range(of: Data("XMPMARK".utf8)))
        XCTAssertNil(searchable.range(of: Data("INFOMARK".utf8)))
        let reloaded = try XCTUnwrap(PDFDocument(data: output))
        XCTAssertEqual(reloaded.outlineRoot?.child(at: 0)?.label, "BOOKMARKTITLE")
        XCTAssertTrue(reloaded.string?.contains("VISIBLEMARK") ?? false)
    }

    func testAssessmentFailsWhenHiddenDataRemains() {
        let failed = CleanupSanitizeAssessment.evaluate(sourcePageCount: 1, outputPageCount: 1,
                                                        remainingMetadataFields: [],
                                                        hiddenData: [.xmpMetadata, .embeddedFiles])
        XCTAssertEqual(failed.verdict, .failed)
        XCTAssertEqual(failed.warnings, ["Hidden data remains in the output: XMP metadata, embedded files."])

        let unchecked = CleanupSanitizeAssessment.evaluate(sourcePageCount: 1, outputPageCount: 1,
                                                           remainingMetadataFields: [], hiddenData: nil)
        XCTAssertEqual(unchecked.verdict, .reviewRequired)

        let passed = CleanupSanitizeAssessment.evaluate(sourcePageCount: 1, outputPageCount: 1,
                                                        remainingMetadataFields: [], hiddenData: [])
        XCTAssertEqual(passed.verdict, .passed)
        XCTAssertTrue(passed.warnings.isEmpty)
    }

    func testAssessmentAsksForReviewWhenSearchableTextIsLost() {
        let lost = CleanupSanitizeAssessment.evaluate(sourcePageCount: 1, outputPageCount: 1,
                                                      remainingMetadataFields: [], hiddenData: [],
                                                      searchableText: (source: 1000, output: 0))
        XCTAssertEqual(lost.verdict, .reviewRequired)
        XCTAssertEqual(lost.warnings, ["Searchable text decreased by 1000 of 1000 characters."])

        let kept = CleanupSanitizeAssessment.evaluate(sourcePageCount: 1, outputPageCount: 1,
                                                      remainingMetadataFields: [], hiddenData: [],
                                                      searchableText: (source: 1000, output: 995))
        XCTAssertEqual(kept.verdict, .passed)
    }

    func testEraserRefusesStreamsWithoutATrustedLength() throws {
        // The catalog below sits inside stream data and must not be read as an object.
        let hidden = "endstream\nendobj\n9 0 obj\n<< /Type /Catalog /Metadata 5 0 R >>\nendobj\n"
        let data = Self.rawPDF(objects: [
            1: "<< /Type /Catalog /Pages 2 0 R /Metadata 5 0 R >>",
            2: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            3: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>",
            4: "<< /Length 6 0 R >>\nstream\n\(hidden)\nendstream",
            5: "<< /Type /Metadata /Subtype /XML /Length 7 >>\nstream\nXMPMARK\nendstream",
            6: "\(hidden.utf8.count)",
        ], info: nil)

        XCTAssertNil(PDFXMPEraser.erasingMetadataStreams(from: data))
    }

    /// A /Length in a nested dictionary must not decide where the stream ends:
    /// the bytes after the false end would be read as objects.
    func testEraserIgnoresNestedLengthAndObjectsMissingFromTheTable() throws {
        let body = "AAAAA\nendstream\nendobj\n777 0 obj\n<< /Metadata 4 0 R >>\nendobj\n"
        let data = Self.rawPDF(objects: [
            1: "<< /Type /Catalog /Pages 2 0 R /Metadata 5 0 R >>",
            2: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            3: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>",
            4: "<< /Subtype /XML /Length 15 >>\nstream\nBT (KEEP) Tj ET\nendstream",
            5: "<< /Type /Metadata /Subtype /XML /Length \(body.utf8.count) /A << /Length 5 >> >>\nstream\n\(body)\nendstream",
        ], info: nil)

        let erased = try XCTUnwrap(PDFXMPEraser.erasingMetadataStreams(from: data))

        XCTAssertNotNil(erased.range(of: Data("BT (KEEP) Tj ET".utf8)), "Page content was erased")
        XCTAssertNil(erased.range(of: Data("AAAAA".utf8)), "XMP stream was not erased")
        XCTAssertEqual(PDFHiddenDataScanner.scan(data: erased), [])
    }

    /// An appended update redefines objects; the superseded XMP is still in the file.
    func testEraserHandlesAnAppendedUpdate() throws {
        let first = Self.rawPDF(objects: [
            1: "<< /Type /Catalog /Pages 2 0 R /Metadata 4 0 R >>",
            2: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            3: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
            4: "<< /Type /Metadata /Subtype /XML /Length 7 >>\nstream\nOLDMARK\nendstream",
        ], info: nil)
        let previousTable = try XCTUnwrap(first.range(of: Data("xref".utf8))).lowerBound
        var data = first
        let offset = data.count
        data.append(Data("4 0 obj\n<< /Type /Metadata /Subtype /XML /Length 7 >>\nstream\nNEWMARK\nendstream\nendobj\n".utf8))
        let table = data.count
        data.append(Data(("xref\n4 1\n" + String(format: "%010d 00000 n \n", offset)
                + "trailer\n<< /Size 5 /Root 1 0 R /Prev \(previousTable) >>\nstartxref\n\(table)\n%%EOF\n").utf8))
        XCTAssertEqual(PDFHiddenDataScanner.scan(data: data), [.xmpMetadata])

        let erased = try PDFXMPEraser.erase(from: data).get()

        XCTAssertEqual(PDFHiddenDataScanner.scan(data: erased), [])
        XCTAssertNil(erased.range(of: Data("OLDMARK".utf8)))
        XCTAssertNil(erased.range(of: Data("NEWMARK".utf8)))
    }

    func testMetadataCleanedExportKeepsRemoteBookmark() throws {
        let data = Self.rawPDF(objects: [
            1: "<< /Type /Catalog /Pages 2 0 R /Metadata 5 0 R /Outlines 6 0 R >>",
            2: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            3: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
            5: "<< /Type /Metadata /Subtype /XML /Length 7 >>\nstream\nXMPMARK\nendstream",
            6: "<< /Type /Outlines /First 7 0 R /Last 7 0 R /Count 1 >>",
            7: "<< /Title (Remote chapter) /Parent 6 0 R /A << /S /GoToR /F (linked.pdf) /D [0 /XYZ 12 34 1.25] >> >>",
        ], info: nil)
        let source = try XCTUnwrap(PDFDocument(data: data))
        // The ordinary write must be erasable in place: the full rewrite cannot keep a remote bookmark.
        let ordinary = try PDFDocumentSerializer.data(from: source,
                                                      remoteBaseline: PDFDocumentSerializer.remoteBaseline(for: source))
        if case let .failure(refusal) = PDFXMPEraser.erase(from: ordinary) {
            let dump = String(decoding: ordinary, as: UTF8.self)
            XCTFail("Eraser refused the ordinary write: \(refusal.rawValue)\n\(dump.prefix(6000))")
        }

        let output = try PDFOps.metadataCleanedData(document: source,
                                                    remoteBaseline: PDFDocumentSerializer.remoteBaseline(for: source))

        XCTAssertFalse(try XCTUnwrap(PDFHiddenDataScanner.scan(data: output)).contains(.xmpMetadata))
        XCTAssertNil(Self.searchableBytes(of: output).range(of: Data("XMPMARK".utf8)))
        let bookmark = try XCTUnwrap(PDFDocument(data: output)?.outlineRoot?.child(at: 0))
        XCTAssertEqual(bookmark.label, "Remote chapter")
        XCTAssertNotNil(output.range(of: Data("/GoToR".utf8)))
        XCTAssertNotNil(output.range(of: Data("linked.pdf".utf8)))
    }

    func testCleanupReviewFailsForOutputThatKeepsHiddenData() throws {
        let leaking = Self.fixture(outline: false)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HiddenDataSanitizeTests-\(UUID().uuidString).pdf")
        try leaking.write(to: outputURL)
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let review = try CleanupReviewBuilder.build(sourceData: leaking, sourceFileName: "source.pdf",
                                                    outputURL: outputURL, profile: .lightClean)
        defer { review.removeTemporarySource() }

        XCTAssertEqual(review.evidence.verdict, .failed)
        XCTAssertTrue(review.evidence.warnings.contains { $0.hasPrefix("Hidden data remains in the output:") })
    }

    // MARK: - Fixture

    /// One page carrying each kind of hidden data, each tagged with a unique marker.
    private static func fixture(outline: Bool) -> Data {
        func stream(_ dictionary: String, _ body: String) -> String {
            "<< \(dictionary) /Length \(body.utf8.count) >>\nstream\n\(body)\nendstream"
        }
        let xmp = "<?xpacket begin=\"\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?><x:xmpmeta xmlns:x=\"adobe:ns:meta/\">"
            + "XMPMARK</x:xmpmeta><?xpacket end=\"w\"?>"
        let content = "BT /F1 24 Tf 72 700 Td (VISIBLEMARK) Tj ET\n"
            + "/OC /oc1 BDC BT /F1 24 Tf 72 600 Td (OCGMARKTEXT) Tj ET EMC\n"
        var catalog = "<< /Type /Catalog /Pages 2 0 R /Metadata 5 0 R"
            + " /Names << /EmbeddedFiles 6 0 R /JavaScript 9 0 R >> /OpenAction 11 0 R /AA << /WC 11 0 R >>"
            + " /PieceInfo << /App << /Private (PIECEMARK) >> >> /AcroForm << /Fields [13 0 R] >>"
            + " /OCProperties << /OCGs [14 0 R] /D << /OFF [14 0 R] /Order [14 0 R] >> >>"
        if outline { catalog += " /Outlines 15 0 R" }
        catalog += " >>"

        var objects: [Int: String] = [
            1: catalog,
            2: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            3: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792]"
                + " /Resources << /Font << /F1 4 0 R >> /Properties << /oc1 14 0 R >> >> /Contents 10 0 R"
                + " /Annots [13 0 R 18 0 R 20 0 R] /PieceInfo << /App << /Private (PIECEMARK) >> >>"
                + " /AA << /O 22 0 R >> >>",
            4: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            5: stream("/Type /Metadata /Subtype /XML", xmp),
            6: "<< /Names [(ATTNAMEMARK.txt) 7 0 R] >>",
            7: "<< /Type /Filespec /F (ATTNAMEMARK.txt) /EF << /F 8 0 R >> >>",
            8: stream("/Type /EmbeddedFile", "ATTACHMARKBODY"),
            9: "<< /Names [(docjs) 11 0 R] >>",
            10: stream("", content),
            11: "<< /Type /Action /S /JavaScript /JS (JSMARKCODE) >>",
            13: "<< /Type /Annot /Subtype /Widget /FT /Tx /T (fieldname) /V (FIELDVALUE) /Rect [72 500 300 530]"
                + " /F 4 /DA (/Helv 12 Tf 0 g) /P 3 0 R >>",
            14: "<< /Type /OCG /Name (OCGMARKLAYER) >>",
            17: "<< /Author (INFOMARKAUTHOR) /Title (INFOMARKTITLE) >>",
            18: "<< /Type /Annot /Subtype /FileAttachment /Rect [400 700 420 720] /FS 19 0 R /Contents (FAANNOTMARK) >>",
            19: "<< /Type /Filespec /F (FANAME.txt) /EF << /F 21 0 R >> >>",
            20: "<< /Type /Annot /Subtype /Link /Rect [72 300 300 320] /A << /S /JavaScript /JS (LINKJSMARK) >> >>",
            21: stream("/Type /EmbeddedFile", "FABODYMARK"),
            22: "<< /Type /Action /S /JavaScript /JS (PAGEAAMARK) >>",
        ]
        if outline {
            objects[15] = "<< /Type /Outlines /First 16 0 R /Last 16 0 R /Count 1 >>"
            objects[16] = "<< /Title (BOOKMARKTITLE) /Parent 15 0 R /Dest [3 0 R /XYZ 0 792 0] >>"
        }

        return rawPDF(objects: objects, info: 17)
    }

    /// Two pages: a link from the first to the second, a radio group with the
    /// second button selected, and XMP in the catalog.
    private static func linkedFormFixture() -> Data {
        let appearance = "<< /Type /XObject /Subtype /Form /BBox [0 0 15 15] /Length 0 >>\nstream\n\nendstream"
        func radio(_ name: String, x: Int, selected: Bool) -> String {
            "<< /Type /Annot /Subtype /Widget /Parent 8 0 R /Rect [\(x) 600 \(x + 15) 615] /F 4 /P 3 0 R"
                + " /AS /\(selected ? name : "Off") /AP << /N << /\(name) 11 0 R /Off 11 0 R >> >> >>"
        }
        return rawPDF(objects: [
            1: "<< /Type /Catalog /Pages 2 0 R /Metadata 5 0 R /AcroForm << /Fields [8 0 R] >> >>",
            2: "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            3: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [7 0 R 9 0 R 10 0 R] >>",
            4: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
            5: "<< /Type /Metadata /Subtype /XML /Length 7 >>\nstream\nXMPMARK\nendstream",
            7: "<< /Type /Annot /Subtype /Link /Rect [72 700 300 720] /Dest [4 0 R /Fit] >>",
            8: "<< /FT /Btn /Ff 49152 /T (radio) /V /B /Kids [9 0 R 10 0 R] >>",
            9: radio("A", x: 72, selected: false),
            10: radio("B", x: 100, selected: true),
            11: appearance,
        ], info: nil)
    }

    private static func rawPDF(objects: [Int: String], info: Int?) -> Data {
        var output = Data("%PDF-1.7\n".utf8)
        var offsets: [Int: Int] = [:]
        for number in objects.keys.sorted() {
            offsets[number] = output.count
            output.append(Data("\(number) 0 obj\n\(objects[number]!)\nendobj\n".utf8))
        }
        let size = (objects.keys.max() ?? 0) + 1
        let xref = output.count
        var table = "xref\n0 \(size)\n0000000000 65535 f \n"
        for number in 1 ..< size {
            if let offset = offsets[number] {
                table += String(format: "%010d 00000 n \n", offset)
            } else {
                table += "0000000000 65535 f \n"
            }
        }
        let infoEntry = info.map { " /Info \($0) 0 R" } ?? ""
        table += "trailer\n<< /Size \(size) /Root 1 0 R\(infoEntry) >>\nstartxref\n\(xref)\n%%EOF\n"
        output.append(Data(table.utf8))
        return output
    }

    /// Raw bytes plus every Flate stream inflated, with UTF-16 padding removed,
    /// so a marker cannot hide behind compression or string encoding.
    private static func searchableBytes(of data: Data) -> Data {
        var combined = data
        let startToken = Data("stream".utf8)
        let endToken = Data("endstream".utf8)
        var cursor = data.startIndex
        while let start = data.range(of: startToken, in: cursor ..< data.endIndex) {
            var bodyStart = start.upperBound
            while bodyStart < data.endIndex, data[bodyStart] == 0x0D || data[bodyStart] == 0x0A { bodyStart += 1 }
            guard let end = data.range(of: endToken, in: bodyStart ..< data.endIndex) else { break }
            if let inflated = inflate(data.subdata(in: bodyStart ..< end.lowerBound)) {
                combined.append(inflated)
            }
            cursor = end.upperBound
        }
        combined.append(Data(combined.filter { $0 != 0 }))
        return combined
    }

    private static func inflate(_ zlibData: Data) -> Data? {
        guard zlibData.count > 2 else { return nil }
        let deflate = zlibData.dropFirst(2)
        var capacity = max(deflate.count * 8, 4096)
        while capacity <= 64 << 20 {
            var destination = Data(count: capacity)
            let written = destination.withUnsafeMutableBytes { target in
                deflate.withUnsafeBytes { source in
                    compression_decode_buffer(target.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                              source.bindMemory(to: UInt8.self).baseAddress!, deflate.count,
                                              nil, COMPRESSION_ZLIB)
                }
            }
            if written == 0 { return nil }
            if written < capacity { return destination.prefix(written) }
            capacity *= 2
        }
        return nil
    }
}
