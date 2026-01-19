import Foundation

/// A user-saveable sanitization preset.
/// Supports forward compatibility by rejecting future versions.
public struct SanitizePreset: Codable, Equatable, Sendable {
    /// Schema version for forward compatibility
    public static let currentVersion = 1
    
    public let version: Int
    public let name: String
    public let profile: SanitizeProfile
    
    public init(name: String, profile: SanitizeProfile, version: Int = currentVersion) {
        self.version = version
        self.name = name
        self.profile = profile
    }
    
    enum CodingKeys: String, CodingKey {
        case version, name, profile
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        // Default to currentVersion if version is missing (backward compatibility)
        let v = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        
        // Reject future versions explicitly
        guard v <= Self.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Unsupported preset version \(v). Maximum supported version is \(Self.currentVersion)."
            )
        }
        
        self.version = v
        
        // Validate name is not empty/whitespace-only
        let rawName = try container.decode(String.self, forKey: .name)
        let trimmedName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .name,
                in: container,
                debugDescription: "Preset name cannot be empty."
            )
        }
        self.name = trimmedName
        
        self.profile = try container.decode(SanitizeProfile.self, forKey: .profile)
    }
}

// MARK: - Flexible Profile Parsing

extension SanitizeProfile {
    /// Parses profile from string, accepting camelCase, kebab-case, and lowercase.
    /// Examples: "privacyClean", "privacy-clean", "privacy_clean" all map to .privacyClean
    public static func parse(_ input: String) -> SanitizeProfile? {
        let normalized = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        
        switch normalized {
        case "privacyclean", "privacy-clean":
            return .privacyClean
        case "lightclean", "light-clean":
            return .lightClean
        case "keepeditable", "keep-editable":
            return .keepEditable
        default:
            return nil
        }
    }
}

