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
        self.name = try container.decode(String.self, forKey: .name)
        self.profile = try container.decode(SanitizeProfile.self, forKey: .profile)
    }
}
