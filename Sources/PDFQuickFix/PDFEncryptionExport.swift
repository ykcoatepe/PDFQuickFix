import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

struct PDFEncryptionOptions {
    let userPassword: String
    let ownerPassword: String?
}

@MainActor
enum PDFEncryptionExport {
    static func requestOptions() -> PDFEncryptionOptions? {
        let userField = NSSecureTextField(string: "")
        userField.placeholderString = "User password"
        let ownerField = NSSecureTextField(string: "")
        ownerField.placeholderString = "Owner password (optional)"

        let stack = NSStackView(views: [userField, ownerField])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = CGRect(x: 0, y: 0, width: 320, height: 56)

        let alert = NSAlert()
        alert.messageText = "Encrypt PDF"
        alert.informativeText = "Set a password for the exported copy."
        alert.accessoryView = stack
        alert.addButton(withTitle: "Encrypt")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let userPassword = userField.stringValue
        guard !userPassword.isEmpty else { return nil }
        let ownerPassword = ownerField.stringValue
        return PDFEncryptionOptions(
            userPassword: userPassword,
            ownerPassword: ownerPassword.isEmpty ? nil : ownerPassword
        )
    }

    static func writeEncryptedCopy(document: PDFDocument,
                                   sourceURL: URL?,
                                   options: PDFEncryptionOptions) throws -> URL?
    {
        let exportDocument = try PDFOps.privacyPreservingDocumentForExport(document)
        guard let data = PDFSecurity.encrypt(
            document: exportDocument,
            userPassword: options.userPassword,
            ownerPassword: options.ownerPassword,
            keyLength: 128
        ) else {
            throw PDFOpsError.saveFailed
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (sourceURL?.deletingPathExtension().lastPathComponent ?? "Document") + "-encrypted.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try data.write(to: url, options: .atomic)
        return url
    }
}
