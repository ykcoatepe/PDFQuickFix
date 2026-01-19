import XCTest
@testable import PDFQuickFixKit

final class SanitizePresetTests: XCTestCase {
    
    // MARK: - Encode/Decode
    
    func testEncodeDecode() throws {
        let preset = SanitizePreset(name: "My Preset", profile: .lightClean)
        let data = try JSONEncoder().encode(preset)
        let decoded = try JSONDecoder().decode(SanitizePreset.self, from: data)
        XCTAssertEqual(preset, decoded)
    }
    
    func testAllProfilesEncode() throws {
        for profile in SanitizeProfile.allCases {
            let preset = SanitizePreset(name: "Test", profile: profile)
            let data = try JSONEncoder().encode(preset)
            let decoded = try JSONDecoder().decode(SanitizePreset.self, from: data)
            XCTAssertEqual(decoded.profile, profile)
            XCTAssertEqual(decoded.version, SanitizePreset.currentVersion)
        }
    }
    
    // MARK: - Version Handling
    
    func testDecodesWithoutVersion() throws {
        // User-written JSON without version field
        let json = """
        {"name": "User Preset", "profile": "keepEditable"}
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SanitizePreset.self, from: data)
        
        XCTAssertEqual(decoded.name, "User Preset")
        XCTAssertEqual(decoded.profile, .keepEditable)
        XCTAssertEqual(decoded.version, SanitizePreset.currentVersion, "Missing version should default to current")
    }
    
    func testDecodesWithExplicitVersion() throws {
        let json = """
        {"version": 1, "name": "Versioned", "profile": "privacyClean"}
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SanitizePreset.self, from: data)
        
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.profile, .privacyClean)
    }
    
    func testRejectsFutureVersion() throws {
        let futureVersion = SanitizePreset.currentVersion + 1
        let json = """
        {"version": \(futureVersion), "name": "Future", "profile": "lightClean"}
        """
        let data = json.data(using: .utf8)!
        
        XCTAssertThrowsError(try JSONDecoder().decode(SanitizePreset.self, from: data)) { error in
            guard case DecodingError.dataCorrupted(let context) = error else {
                XCTFail("Expected dataCorrupted error, got \(error)")
                return
            }
            XCTAssertTrue(context.debugDescription.contains("Unsupported preset version"))
        }
    }
    
    // MARK: - Name Validation
    
    func testRejectsEmptyName() throws {
        let json = """
        {"name": "", "profile": "lightClean"}
        """
        let data = json.data(using: .utf8)!
        
        XCTAssertThrowsError(try JSONDecoder().decode(SanitizePreset.self, from: data)) { error in
            guard case DecodingError.dataCorrupted(let context) = error else {
                XCTFail("Expected dataCorrupted error, got \(error)")
                return
            }
            XCTAssertTrue(context.debugDescription.contains("cannot be empty"))
        }
    }
    
    func testRejectsWhitespaceOnlyName() throws {
        let json = """
        {"name": "   ", "profile": "lightClean"}
        """
        let data = json.data(using: .utf8)!
        
        XCTAssertThrowsError(try JSONDecoder().decode(SanitizePreset.self, from: data)) { error in
            guard case DecodingError.dataCorrupted(let context) = error else {
                XCTFail("Expected dataCorrupted error, got \(error)")
                return
            }
            XCTAssertTrue(context.debugDescription.contains("cannot be empty"))
        }
    }
    
    func testTrimsNameWhitespace() throws {
        let json = """
        {"name": "  My Preset  ", "profile": "lightClean"}
        """
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SanitizePreset.self, from: data)
        
        XCTAssertEqual(decoded.name, "My Preset", "Name should be trimmed")
    }
    
    // MARK: - Profile Codable
    
    func testProfileRawValues() {
        XCTAssertEqual(SanitizeProfile.privacyClean.rawValue, "privacyClean")
        XCTAssertEqual(SanitizeProfile.lightClean.rawValue, "lightClean")
        XCTAssertEqual(SanitizeProfile.keepEditable.rawValue, "keepEditable")
    }
    
    func testProfileFromRawValue() {
        XCTAssertEqual(SanitizeProfile(rawValue: "privacyClean"), .privacyClean)
        XCTAssertEqual(SanitizeProfile(rawValue: "lightClean"), .lightClean)
        XCTAssertEqual(SanitizeProfile(rawValue: "keepEditable"), .keepEditable)
        XCTAssertNil(SanitizeProfile(rawValue: "invalid"))
    }
    
    // MARK: - Flexible Profile Parsing (CLI support)
    
    func testProfileParsesCamelCase() {
        XCTAssertEqual(SanitizeProfile.parse("privacyClean"), .privacyClean)
        XCTAssertEqual(SanitizeProfile.parse("lightClean"), .lightClean)
        XCTAssertEqual(SanitizeProfile.parse("keepEditable"), .keepEditable)
    }
    
    func testProfileParsesKebabCase() {
        XCTAssertEqual(SanitizeProfile.parse("privacy-clean"), .privacyClean)
        XCTAssertEqual(SanitizeProfile.parse("light-clean"), .lightClean)
        XCTAssertEqual(SanitizeProfile.parse("keep-editable"), .keepEditable)
    }
    
    func testProfileParsesLowercase() {
        XCTAssertEqual(SanitizeProfile.parse("privacyclean"), .privacyClean)
        XCTAssertEqual(SanitizeProfile.parse("lightclean"), .lightClean)
        XCTAssertEqual(SanitizeProfile.parse("keepeditable"), .keepEditable)
    }
    
    func testProfileParsesUnderscoreCase() {
        XCTAssertEqual(SanitizeProfile.parse("privacy_clean"), .privacyClean)
        XCTAssertEqual(SanitizeProfile.parse("light_clean"), .lightClean)
        XCTAssertEqual(SanitizeProfile.parse("keep_editable"), .keepEditable)
    }
    
    func testProfileParseTrimsWhitespace() {
        XCTAssertEqual(SanitizeProfile.parse("  privacy-clean  "), .privacyClean)
    }
    
    func testProfileParseRejectsInvalid() {
        XCTAssertNil(SanitizeProfile.parse("invalid"))
        XCTAssertNil(SanitizeProfile.parse(""))
        XCTAssertNil(SanitizeProfile.parse("privacy"))
    }
    
    // MARK: - JSON Roundtrip (proves CLI can load user-written JSON)
    
    func testPresetJSONLoads() throws {
        // Simulates a user-written preset file for CLI
        let preset = SanitizePreset(name: "CLI Test", profile: .keepEditable)
        let data = try JSONEncoder().encode(preset)
        
        // Simulate file write/read cycle
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_preset.json")
        try data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        
        // Verify preset can be loaded (as CLI would do)
        let loadedData = try Data(contentsOf: tempURL)
        let loadedPreset = try JSONDecoder().decode(SanitizePreset.self, from: loadedData)
        XCTAssertEqual(loadedPreset.profile, .keepEditable)
        XCTAssertEqual(loadedPreset.name, "CLI Test")
    }
}

