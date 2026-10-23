import Foundation

public struct PDFCoreObjectRef: Hashable {
    public let objectNumber: Int
    public let generation: Int

    public init(objectNumber: Int, generation: Int) {
        self.objectNumber = objectNumber
        self.generation = generation
    }
}

public struct PDFCoreDocument {
    public var objects: [PDFCoreObjectRef: PDFCoreObject]
    public var rootRef: PDFCoreObjectRef?
    public var infoRef: PDFCoreObjectRef?
    public var isEncrypted: Bool

    public init(objects: [PDFCoreObjectRef: PDFCoreObject] = [:],
                rootRef: PDFCoreObjectRef? = nil,
                infoRef: PDFCoreObjectRef? = nil,
                isEncrypted: Bool = false)
    {
        self.objects = objects
        self.rootRef = rootRef
        self.infoRef = infoRef
        self.isEncrypted = isEncrypted
    }
}
