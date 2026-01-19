import Foundation
import PDFQuickFixKit

/// Manages sanitize profile defaults for the App.
/// Stores the user's default sanitization profile preference.
@MainActor
final class SanitizeDefaults: ObservableObject {
    static let shared = SanitizeDefaults()
    
    private let userDefaultsKey = "defaultSanitizeProfile"
    
    /// User's default sanitize profile (persisted via UserDefaults)
    @Published var defaultProfile: SanitizeProfile {
        didSet {
            UserDefaults.standard.set(defaultProfile.rawValue, forKey: userDefaultsKey)
        }
    }
    
    private init() {
        if let raw = UserDefaults.standard.string(forKey: userDefaultsKey),
           let profile = SanitizeProfile(rawValue: raw) {
            self.defaultProfile = profile
        } else {
            self.defaultProfile = .privacyClean
        }
    }
}
