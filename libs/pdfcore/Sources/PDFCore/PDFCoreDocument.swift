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
    
    public init(objects: [PDFCoreObjectRef: PDFCoreObject] = [:],
                rootRef: PDFCoreObjectRef? = nil,
                infoRef: PDFCoreObjectRef? = nil) {
        self.objects = objects
        self.rootRef = rootRef
        self.infoRef = infoRef
    }
}
