import AppKit
import Foundation
import PDFKit
import PDFQuickFixKit

typealias PDFPasswordProvider = (URL) -> String?

/// Retained only by a controller for the lifetime of this exact open document.
final class PDFDocumentPassword {
    private weak var document: PDFDocument?
    private let password: String?
    private let requiresUserPassword: Bool

    init(document: PDFDocument, password: String?, requiresUserPassword: Bool = true) {
        self.document = document
        self.password = password
        self.requiresUserPassword = requiresUserPassword
    }

    func password(for candidate: PDFDocument) -> String? {
        document === candidate ? password : nil
    }

    func requiresUserPassword(for candidate: PDFDocument) -> Bool? {
        document === candidate ? requiresUserPassword : nil
    }
}

enum PDFVerifiedSave {
    enum SaveError: LocalizedError {
        case documentChanged
        var errorDescription: String? { "The open document changed during password verification. The destination was not changed." }
    }

    /// Credentials are passed by value because the password UI runs a nested event
    /// loop. The caller rechecks its adoption generation before committing results.
    static func write(_ document: PDFDocument,
                      to destination: URL,
                      sourceURL: URL?,
                      credential: PDFDocumentPassword?,
                      remoteBaseline: PDFDocumentSerializer.RemoteOutlineBaseline?,
                      isCurrent: () -> Bool,
                      passwordProvider: PDFPasswordProvider) throws -> PDFDocumentPassword?
    {
        guard isCurrent() else { throw SaveError.documentChanged }
        do {
            try PDFDocumentSerializer.write(document, to: destination,
                                            verificationPassword: credential?.password(for: document),
                                            requiresUserPassword: credential?.requiresUserPassword(for: document),
                                            remoteBaseline: remoteBaseline)
            return credential
        } catch PDFDocumentSerializationError.verificationPasswordRequired {
            let password = passwordProvider(sourceURL ?? document.documentURL ?? destination)
            guard isCurrent() else { throw SaveError.documentChanged }
            guard let password else { throw PDFDocumentSerializationError.verificationPasswordRequired }
            try PDFDocumentSerializer.write(document, to: destination, verificationPassword: password,
                                            requiresUserPassword: credential?.requiresUserPassword(for: document),
                                            remoteBaseline: remoteBaseline)
            return PDFDocumentPassword(document: document, password: password,
                                       requiresUserPassword: credential?.requiresUserPassword(for: document) ?? true)
        }
    }
}

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
