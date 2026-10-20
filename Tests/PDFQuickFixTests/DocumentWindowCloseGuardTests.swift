import XCTest
@testable import PDFQuickFix

@MainActor
final class DocumentWindowCloseGuardTests: XCTestCase {
    func testCancelInInactiveDocumentPreventsWindowClose() {
        var visited = 0
        let approval = DocumentCloseTransaction.authorize([
            { visited += 1; return DocumentCloseAuthorization { true } },
            { visited += 1; return nil },
        ])
        XCTAssertNil(approval)
        XCTAssertEqual(visited, 2)
    }

    func testLaterPromptChangingEarlierDocumentInvalidatesAllApprovals() {
        var revision = 0
        let approval = DocumentCloseTransaction.authorize([
            {
                let captured = revision
                return DocumentCloseAuthorization { revision == captured }
            },
            {
                revision += 1
                return DocumentCloseAuthorization { true }
            },
        ])
        XCTAssertNil(approval)
    }

    func testApprovalMustStillBeCurrentWhenCloseCommits() throws {
        var current = true
        let approval = try XCTUnwrap(DocumentCloseTransaction.authorize([
            { DocumentCloseAuthorization { current } },
        ]))
        current = false
        XCTAssertFalse(approval.isCurrent())
    }

    func testQuitIncludesEveryRegisteredWindow() {
        let registry = DocumentCloseRegistry()
        let first = NSObject()
        let second = NSObject()
        var visited: Set<String> = []
        registry.register(first) {
            visited.insert("first")
            return DocumentCloseAuthorization { true }
        }
        registry.register(second) {
            visited.insert("second")
            return DocumentCloseAuthorization { true }
        }
        XCTAssertTrue(registry.authorizeTermination())
        XCTAssertEqual(visited, ["first", "second"])
    }

    func testNewWindowDuringPromptInvalidatesQuit() {
        let registry = DocumentCloseRegistry()
        let first = NSObject()
        let newWindow = NSObject()
        registry.register(first) {
            registry.register(newWindow) { nil }
            return DocumentCloseAuthorization { true }
        }
        XCTAssertFalse(registry.authorizeTermination())
    }

    func testReentrantQuitIsDenied() {
        let registry = DocumentCloseRegistry()
        let owner = NSObject()
        registry.register(owner) {
            XCTAssertFalse(registry.authorizeTermination())
            return DocumentCloseAuthorization { true }
        }
        XCTAssertTrue(registry.authorizeTermination())
    }

    func testDetachedWindowCannotBlockQuit() {
        let registry = DocumentCloseRegistry()
        let owner = NSObject()
        registry.register(owner) { nil }
        registry.unregister(owner)
        XCTAssertTrue(registry.authorizeTermination())
    }
}
