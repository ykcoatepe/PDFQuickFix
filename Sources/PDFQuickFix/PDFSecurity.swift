import CoreGraphics
import Foundation
import PDFKit
import PDFQuickFixKit

enum PDFSecurity {
    static func encrypt(
        document: PDFDocument,
        userPassword: String,
        ownerPassword: String? = nil,
        keyLength: Int = 128,
        remoteBaseline: PDFDocumentSerializer.RemoteOutlineBaseline? = nil
    ) -> Data? {
        guard document.pageCount > 0 else { return nil }
        guard keyLength == 40 || keyLength == 128 else { return nil }

        let highQualityPrintingPermission = 1 << 1

        let options: [AnyHashable: Any] = [
            PDFDocumentWriteOption.userPasswordOption: userPassword,
            PDFDocumentWriteOption.ownerPasswordOption: ownerPassword ?? userPassword,
            kCGPDFContextEncryptionKeyLength as String: keyLength,
            PDFDocumentWriteOption.accessPermissionsOption: NSNumber(value: highQualityPrintingPermission),
        ]

        return try? PDFDocumentSerializer.data(from: document, options: options, remoteBaseline: remoteBaseline)
    }
}
