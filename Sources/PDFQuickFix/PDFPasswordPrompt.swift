import AppKit
import Foundation
import PDFKit

typealias PDFPasswordProvider = (URL) -> String?

enum PDFPasswordPrompt {
    static func requestPassword(for url: URL) -> String? {
        let field = NSSecureTextField(string: "")
        field.placeholderString = "Password"
        field.frame = CGRect(x: 0, y: 0, width: 320, height: 24)

        let alert = NSAlert()
        alert.messageText = "Password Required"
        alert.informativeText = "\(url.lastPathComponent) is encrypted."
        alert.accessoryView = field
        alert.addButton(withTitle: "Unlock")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let password = field.stringValue
        return password.isEmpty ? nil : password
    }
}

enum PDFPasswordUnlock {
    static func unlockIfNeeded(document: PDFDocument,
                               url: URL,
                               passwordProvider: PDFPasswordProvider) -> Bool
    {
        guard document.isEncrypted, document.isLocked else { return true }
        guard let password = passwordProvider(url) else { return false }
        return document.unlock(withPassword: password)
    }
}
