import XCTest
@testable import PDFQuickFix

final class DocumentProfileTests: XCTestCase {
    
    func testNormalDocument() {
        let profile = DocumentProfile.from(pageCount: 100)
        XCTAssertFalse(profile.isLarge)
        XCTAssertFalse(profile.isMassive)
        XCTAssertTrue(profile.searchEnabled)
        XCTAssertTrue(profile.thumbnailsEnabled)
        XCTAssertTrue(profile.studioEnabled)
    }
    
    func testLargeDocument() {
        let threshold = DocumentValidationRunner.largeDocumentPageThreshold
        let profile = DocumentProfile.from(pageCount: threshold + 1)
        XCTAssertTrue(profile.isLarge)
        XCTAssertFalse(profile.isMassive)
        // Large docs still have search/studio enabled, just tuned
        XCTAssertTrue(profile.searchEnabled)
        XCTAssertTrue(profile.thumbnailsEnabled)
        XCTAssertTrue(profile.studioEnabled)
    }
    
    func testMassiveDocument() {
        let threshold = DocumentValidationRunner.massiveDocumentPageThreshold
        let profile = DocumentProfile.from(pageCount: threshold)
        XCTAssertTrue(profile.isLarge) // Massive implies large
        XCTAssertTrue(profile.isMassive)
        
        // Features disabled
        XCTAssertFalse(profile.searchEnabled)
        XCTAssertFalse(profile.thumbnailsEnabled)
        XCTAssertFalse(profile.studioEnabled)
        XCTAssertFalse(profile.globalAnnotationsEnabled)
        XCTAssertFalse(profile.outlineEnabled)
    }
    
    func testMassiveFileSize() {
        // 201 MB
        let size: Int64 = 201 * 1024 * 1024
        let profile = DocumentProfile.from(pageCount: 100, fileSizeBytes: size)
        XCTAssertTrue(profile.isMassive)
        XCTAssertFalse(profile.searchEnabled)
    }
    
    func testMixedMassiveConditions() {
        // Small page count, massive size -> Massive
        let size: Int64 = 201 * 1024 * 1024
        let profile1 = DocumentProfile.from(pageCount: 50, fileSizeBytes: size)
        XCTAssertTrue(profile1.isMassive)
        
        // Massive page count, small size -> Massive
        let threshold = DocumentValidationRunner.massiveDocumentPageThreshold
        let profile2 = DocumentProfile.from(pageCount: threshold, fileSizeBytes: 1024)
        XCTAssertTrue(profile2.isMassive)
        
        // Boundary check: 199 MB -> Not Massive (if pages low)
        let sizeSmall: Int64 = 199 * 1024 * 1024
        let profile3 = DocumentProfile.from(pageCount: 100, fileSizeBytes: sizeSmall)
        XCTAssertFalse(profile3.isMassive)
    }
    
    func testEmptyProfile() {
        let profile = DocumentProfile.empty
        XCTAssertFalse(profile.isLarge)
        XCTAssertFalse(profile.isMassive)
        XCTAssertFalse(profile.searchEnabled)
    }
}
