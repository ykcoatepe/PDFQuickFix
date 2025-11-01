import Foundation
import PDFKit
import CoreGraphics

enum PDFSecurity {
    static func encrypt(
        document: PDFDocument,
        userPassword: String,
        ownerPassword: String? = nil,
        keyLength: Int = 256
    ) -> Data? {
        guard document.pageCount > 0 else { return nil }
        
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        
        let options: [CFString: Any] = [
            kCGPDFContextUserPassword: userPassword,
            kCGPDFContextOwnerPassword: ownerPassword ?? userPassword,
            kCGPDFContextEncryptionKeyLength: keyLength,
            kCGPDFContextAllowsCopying: false,
            kCGPDFContextAllowsPrinting: true
        ]
        
        var mediaBox = document.page(at: 0)?.bounds(for: .mediaBox) ?? .zero
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, options as CFDictionary) else {
            return nil
        }
        
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex), let pageRef = page.pageRef else { continue }
            let box = pageRef.getBoxRect(.mediaBox)
            context.beginPDFPage([kCGPDFContextMediaBox as String: box] as CFDictionary)
            context.drawPDFPage(pageRef)
            context.endPDFPage()
        }
        
        context.closePDF()
        return data as Data
    }
}
