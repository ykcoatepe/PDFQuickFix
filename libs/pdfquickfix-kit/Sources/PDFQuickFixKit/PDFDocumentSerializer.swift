import CoreGraphics
import Foundation
import PDFKit

public enum PDFDocumentSerializationError: LocalizedError {
    case serializationFailed
    case invalidOutline
    case unsupportedOutlineAction(String)
    case validationFailed
    case verificationPasswordRequired
    case remoteOutlineVerificationRequired
    case ownerPermissionsVerificationRequired

    public var errorDescription: String? {
        switch self {
        case .serializationFailed:
            "The PDF could not be serialized. The destination was not changed."
        case .invalidOutline:
            "A bookmark has an invalid document destination. The destination was not changed."
        case let .unsupportedOutlineAction(type):
            "Bookmark action \(type) cannot be verified for saving. The destination was not changed."
        case .validationFailed:
            "The saved PDF did not preserve its pages, bookmarks, or protection. The destination was not changed."
        case .verificationPasswordRequired:
            "A password is required to verify the protected PDF before saving. The destination was not changed."
        case .remoteOutlineVerificationRequired:
            "Remote PDF bookmarks changed or have no verified baseline. Their target edits cannot be saved safely. The destination was not changed."
        case .ownerPermissionsVerificationRequired:
            "The PDF is open with owner access, so its user permissions cannot be verified for an ordinary save. Use Export Encrypted Copy with explicit permissions and passwords. The destination was not changed."
        }
    }
}

/// Writes the current outline rather than PDFKit's cached source-file outline.
/// The caller must exclusively own the document throughout this synchronous operation:
/// a missing root is temporarily represented by an empty root, then restored.
/// Plain output is checked for ordered labels, hierarchy, local destinations and URL
/// actions after unlocking protected candidates with a call-scoped credential.
/// This API neither removes encryption nor stores credentials.
public enum PDFDocumentSerializer {
    /// Capture at successful open/adoption, before edits. Public PDFKit GoToR
    /// properties do not faithfully expose all raw target operands. This token
    /// proves remote objects, their order and exposed fields have not changed;
    /// candidate bytes must also retain the complete ordered raw F/D sequence.
    public final class RemoteOutlineBaseline {
        fileprivate weak var document: PDFDocument?
        fileprivate let handles: [RemoteHandle]
        fileprivate let targets: [RemoteDestination]

        public var hasRemoteTargets: Bool { !targets.isEmpty }

        fileprivate init(document: PDFDocument, handles: [RemoteHandle], targets: [RemoteDestination]) {
            self.document = document
            self.handles = handles
            self.targets = targets
        }
    }

    public static func remoteBaseline(for document: PDFDocument) throws -> RemoteOutlineBaseline {
        let handles = try remoteHandles(in: document)
        let targets = try remoteTargets(in: document)
        guard handles.count == targets.count else { throw PDFDocumentSerializationError.remoteOutlineVerificationRequired }
        return RemoteOutlineBaseline(document: document, handles: handles, targets: targets)
    }

    public static func data(from document: PDFDocument,
                            options: [AnyHashable: Any] = [:],
                            verificationPassword: String? = nil,
                            requiresUserPassword: Bool? = nil,
                            removingOutline: Bool = false,
                            remoteBaseline: RemoteOutlineBaseline? = nil) throws -> Data
    {
        guard !document.isLocked else { throw PDFDocumentSerializationError.serializationFailed }
        let expectedOutline = removingOutline ? [] : try outlineEntries(in: document)
        let expectedRemotes: [RemoteDestination]
        if removingOutline {
            expectedRemotes = []
        } else {
            let handles = try remoteHandles(in: document)
            if handles.isEmpty, try remoteTargets(in: document).isEmpty {
                expectedRemotes = []
            } else {
                guard let remoteBaseline, remoteBaseline.document === document,
                      handles.count == remoteBaseline.handles.count,
                      zip(handles, remoteBaseline.handles).allSatisfy({ $0.matches($1) })
                else { throw PDFDocumentSerializationError.remoteOutlineVerificationRequired }
                expectedRemotes = remoteBaseline.targets
            }
        }
        let originalRoot = document.outlineRoot
        if originalRoot == nil || removingOutline { document.outlineRoot = PDFOutline() }
        defer {
            if originalRoot == nil || removingOutline { document.outlineRoot = originalRoot }
        }

        let ownerPassword = options[PDFDocumentWriteOption.ownerPasswordOption] as? String
        let userPassword = options[PDFDocumentWriteOption.userPasswordOption] as? String
        let requestsEncryption = !(ownerPassword ?? "").isEmpty || !(userPassword ?? "").isEmpty
        // Owner unlocking can hide the underlying user restrictions by reporting
        // full privileges. A matching public mask is not proof of preserved /P.
        guard !document.isEncrypted || requestsEncryption || document.permissionsStatus != .owner else {
            throw PDFDocumentSerializationError.ownerPermissionsVerificationRequired
        }
        let expectsEncryption = document.isEncrypted || requestsEncryption
        // A previously unlocked document no longer exposes its original lock
        // state. Unknown protected sources fail closed; openers can supply the
        // observed requirement, including owner-only encryption with an empty user password.
        let expectsLocked = requestsEncryption ? !(userPassword ?? "").isEmpty
            : document.isEncrypted && (requiresUserPassword ?? true)
        let password = userPassword ?? ownerPassword ?? verificationPassword
        let linearizedKey = kCGPDFContextCreateLinearizedPDF as String
        var attempts = [options]
        // Ordinary output can preserve legacy encryption better and avoids a full
        // rewrite when the existing outline is already correct. Retry only after a
        // failed validation, using the documented CoreGraphics full-write option.
        if options[linearizedKey] == nil {
            var linearizedOptions = options
            linearizedOptions[linearizedKey] = true
            attempts.append(linearizedOptions)
        }
        var failure: PDFDocumentSerializationError = .serializationFailed
        for writeOptions in attempts {
            guard let data = document.dataRepresentation(options: writeOptions),
                  let candidate = PDFDocument(data: data)
            else { continue }
            guard candidate.isEncrypted == expectsEncryption,
                  candidate.isLocked == expectsLocked
            else {
                failure = .validationFailed
                continue
            }
            if candidate.isLocked, !candidate.unlock(withPassword: password ?? "") {
                // Without a credential a different write mode cannot verify output.
                guard password != nil else { throw PDFDocumentSerializationError.verificationPasswordRequired }
                failure = .validationFailed
                continue
            }
            if requestsEncryption, !validatesEncryption(data, userPassword: userPassword,
                                                        ownerPassword: ownerPassword, options: options) {
                failure = .validationFailed
                continue
            }
            if document.isEncrypted, !requestsEncryption,
               (candidate.permissionsStatus != document.permissionsStatus
                || candidate.accessPermissions != document.accessPermissions)
            {
                failure = .validationFailed
                continue
            }
            guard candidate.pageCount == document.pageCount,
                  (try? outlineEntries(in: candidate)) == expectedOutline,
                  (try? remoteTargets(in: candidate)) == expectedRemotes
            else {
                failure = .validationFailed
                continue
            }
            return data
        }
        throw failure
    }

    /// Verify each supplied credential independently. Owner unlocking must grant
    /// owner status; a user unlock also checks the requested documented permission
    /// supersets before an owner credential can elevate that candidate's access.
    private static func validatesEncryption(_ data: Data, userPassword: String?, ownerPassword: String?,
                                            options: [AnyHashable: Any]) -> Bool {
        guard let user = PDFDocument(data: data), user.unlock(withPassword: userPassword ?? "") else { return false }
        if let requested = options[PDFDocumentWriteOption.accessPermissionsOption] as? NSNumber {
            var permissions = requested.uintValue
            guard permissions & ~UInt(255) == 0 else { return false }
            if permissions & (1 << 1) != 0 { permissions |= 1 << 0 }
            if permissions & (1 << 2) != 0 { permissions |= (1 << 6) | (1 << 7) }
            if permissions & (1 << 4) != 0 { permissions |= 1 << 5 }
            if permissions & (1 << 6) != 0 { permissions |= 1 << 7 }
            guard user.accessPermissions.rawValue == permissions else { return false }
        }
        if let ownerPassword, !ownerPassword.isEmpty {
            guard let owner = PDFDocument(data: data), owner.unlock(withPassword: ownerPassword),
                  owner.permissionsStatus == .owner else { return false }
        }
        return true
    }

    /// Serialization and validation finish before Foundation's atomic replacement.
    /// A serialization/validation failure leaves an existing destination untouched.
    public static func write(_ document: PDFDocument,
                             to destination: URL,
                             options: [AnyHashable: Any] = [:],
                             verificationPassword: String? = nil,
                             requiresUserPassword: Bool? = nil,
                             removingOutline: Bool = false,
                             remoteBaseline: RemoteOutlineBaseline? = nil) throws
    {
        let validatedData = try data(from: document, options: options,
                                    verificationPassword: verificationPassword,
                                    requiresUserPassword: requiresUserPassword, removingOutline: removingOutline,
                                    remoteBaseline: remoteBaseline)
        try validatedData.write(to: destination, options: .atomic)
    }

    /// Atomically exports an already repaired PDF without deleting the old target
    /// or reserializing its contents. The caller owns temporary-source cleanup.
    public static func copyValidatedPDF(from source: URL, to destination: URL) throws {
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        guard let document = PDFDocument(data: data), document.isLocked || document.pageCount > 0 else {
            throw PDFDocumentSerializationError.validationFailed
        }
        try data.write(to: destination, options: .atomic)
    }

    private struct Entry: Equatable {
        let depth: Int
        let label: String?
        let action: Action
    }

    private enum Action: Equatable {
        case none
        case destination(Destination)
        case url(URL)
        case remote
    }

    fileprivate struct RemoteDestination: Equatable {
        let action: RawValue
    }

    fileprivate struct RemoteHandle {
        weak var outline: PDFOutline?
        weak var action: PDFActionRemoteGoTo?
        let page: Int
        let point: CGPoint
        let url: URL?

        func matches(_ other: Self) -> Bool {
            outline != nil && action != nil && outline === other.outline && action === other.action
                && page == other.page && point == other.point && url == other.url
        }
    }

    fileprivate indirect enum RawValue: Equatable {
        case null
        case boolean(Bool)
        case integer(CGPDFInteger)
        case real(CGPDFReal)
        case name(String)
        case string(Data)
        case array([RawValue])
        case dictionary([String: RawValue])
    }

    private struct Destination: Equatable {
        let page: Int
        let point: CGPoint
        let zoom: CGFloat

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.page == rhs.page && close(lhs.point.x, rhs.point.x)
                && close(lhs.point.y, rhs.point.y) && close(lhs.zoom, rhs.zoom)
        }

        private static func close(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
            lhs == rhs || abs(lhs - rhs) <= 0.001
        }
    }

    private static func outlineNodes(in document: PDFDocument) throws -> [(PDFOutline, Int)] {
        guard let root = document.outlineRoot else { return [] }
        var pending: [(PDFOutline, Int)] = [(root, -1)]
        var visited: Set<ObjectIdentifier> = []
        var nodes: [(PDFOutline, Int)] = []
        while let (outline, depth) = pending.popLast() {
            guard visited.count < 100_000,
                  visited.insert(ObjectIdentifier(outline)).inserted else {
                throw PDFDocumentSerializationError.invalidOutline
            }
            if depth >= 0 { nodes.append((outline, depth)) }
            for index in (0 ..< outline.numberOfChildren).reversed() {
                guard let child = outline.child(at: index) else { throw PDFDocumentSerializationError.invalidOutline }
                pending.append((child, depth + 1))
            }
        }
        return nodes
    }

    private static func remoteHandles(in document: PDFDocument) throws -> [RemoteHandle] {
        try outlineNodes(in: document).compactMap { outline, _ in
            guard let action = outline.action as? PDFActionRemoteGoTo else { return nil }
            // Safe access to the public URL getter: PDFKit can return nil despite
            // its nonnull declaration when a relative URL has no document base.
            return RemoteHandle(outline: outline, action: action, page: action.pageIndex,
                                point: action.point, url: action.value(forKey: "URL") as? URL)
        }
    }

    private static func outlineEntries(in document: PDFDocument) throws -> [Entry] {
        try outlineNodes(in: document).map { outline, depth in
            let action: Action
            if let destination = outline.destination ?? (outline.action as? PDFActionGoTo)?.destination {
                guard let page = destination.page else { throw PDFDocumentSerializationError.invalidOutline }
                let index = document.index(for: page)
                guard index != NSNotFound, destination.point.x.isFinite,
                      destination.point.y.isFinite, destination.zoom.isFinite else {
                    throw PDFDocumentSerializationError.invalidOutline
                }
                action = .destination(Destination(page: index, point: destination.point, zoom: destination.zoom))
            } else if let urlAction = outline.action as? PDFActionURL, let url = urlAction.url {
                action = .url(url)
            } else if outline.action is PDFActionRemoteGoTo {
                action = .remote
            } else if let unsupported = outline.action {
                throw PDFDocumentSerializationError.unsupportedOutlineAction(unsupported.type)
            } else {
                action = .none
            }
            return Entry(depth: depth, label: outline.label, action: action)
        }
    }

    private static func remoteTargets(in document: PDFDocument) throws -> [RemoteDestination] {
        guard let reference = document.documentRef, let catalog = reference.catalog else { return [] }
        var root: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(catalog, "Outlines", &root), let root else { return [] }
        var first: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(root, "First", &first), let first else { return [] }
        var pending: [(CGPDFDictionaryRef, Int)] = [(first, 0)]
        var seen: Set<CGPDFDictionaryRef> = []
        var targets: [RemoteDestination] = []
        while let (node, depth) = pending.popLast() {
            guard seen.count < 100_000, seen.insert(node).inserted else {
                throw PDFDocumentSerializationError.invalidOutline
            }
            var next: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(node, "Next", &next), let next { pending.append((next, depth)) }
            var child: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(node, "First", &child), let child { pending.append((child, depth + 1)) }
            var action: CGPDFDictionaryRef?
            var actionObject: CGPDFObjectRef?
            guard CGPDFDictionaryGetDictionary(node, "A", &action), let action,
                  CGPDFDictionaryGetObject(node, "A", &actionObject), let actionObject else { continue }
            var type: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(action, "S", &type), let type, String(cString: type) == "GoToR" else { continue }
            var file: CGPDFObjectRef?
            var operands: CGPDFObjectRef?
            guard CGPDFDictionaryGetObject(action, "F", &file), let file,
                  CGPDFDictionaryGetObject(action, "D", &operands), let operands,
                  remoteFileName(file) != nil
            else { throw PDFDocumentSerializationError.invalidOutline }
            switch CGPDFObjectGetType(operands) {
            case .array:
                var array: CGPDFArrayRef?
                var page: CGPDFInteger = 0
                guard CGPDFObjectGetValue(operands, .array, &array), let array,
                      CGPDFArrayGetCount(array) >= 2, CGPDFArrayGetInteger(array, 0, &page), page >= 0
                else { throw PDFDocumentSerializationError.invalidOutline }
                _ = try remotePoint(array)
            case .name, .string:
                // A remote named destination is resolved by the target PDF. Keep
                // its name/type or string bytes in the full raw action signature;
                // the existing decoder enforces ASCII names and resource budgets.
                break
            default:
                throw PDFDocumentSerializationError.invalidOutline
            }
            var active: Set<CGPDFObjectRef> = []
            var remaining = 10_000
            let rawAction = try rawValue(actionObject, active: &active, remaining: &remaining)
            guard case let .dictionary(values) = rawAction,
                  Set(values.keys).isSubset(of: ["Type", "S", "F", "D", "NewWindow"])
            else { throw PDFDocumentSerializationError.unsupportedOutlineAction("GoToR action fields") }
            if let window = values["NewWindow"], case .boolean = window {} else if values["NewWindow"] != nil {
                throw PDFDocumentSerializationError.invalidOutline
            }
            let signature = RemoteDestination(action: rawAction)
            targets.append(signature)
        }
        return targets
    }

    private static func remotePoint(_ operands: CGPDFArrayRef) throws -> CGPoint? {
        var name: UnsafePointer<CChar>?
        guard CGPDFArrayGetName(operands, 1, &name), let name else { throw PDFDocumentSerializationError.invalidOutline }
        let view = String(cString: name)
        let requiredCount: Int
        switch view {
        case "XYZ": requiredCount = 5
        case "Fit", "FitB": requiredCount = 2
        case "FitH", "FitV", "FitBH", "FitBV": requiredCount = 3
        case "FitR": requiredCount = 6
        default: throw PDFDocumentSerializationError.unsupportedOutlineAction("GoToR view")
        }
        guard CGPDFArrayGetCount(operands) == requiredCount else { throw PDFDocumentSerializationError.invalidOutline }
        var coordinates: [CGFloat] = []
        for index in 2 ..< requiredCount {
            var value: CGPDFReal = 0
            if CGPDFArrayGetNumber(operands, index, &value), value.isFinite {
                coordinates.append(value)
            } else {
                var object: CGPDFObjectRef?
                guard view != "FitR", CGPDFArrayGetObject(operands, index, &object), let object,
                      CGPDFObjectGetType(object) == .null else { throw PDFDocumentSerializationError.invalidOutline }
                coordinates.append(kPDFDestinationUnspecifiedValue)
            }
        }
        return view == "XYZ" ? CGPoint(x: coordinates[0], y: coordinates[1]) : nil
    }

    private static func remoteFileName(_ file: CGPDFObjectRef) -> String? {
        var string: CGPDFStringRef?
        if CGPDFObjectGetValue(file, .string, &string), let string {
            return CGPDFStringCopyTextString(string) as String?
        }
        var dictionary: CGPDFDictionaryRef?
        guard CGPDFObjectGetValue(file, .dictionary, &dictionary), let dictionary else { return nil }
        for key in ["UF", "F"] {
            if CGPDFDictionaryGetString(dictionary, key, &string), let string {
                return CGPDFStringCopyTextString(string) as String?
            }
        }
        return nil
    }

    // Swift String equality normalizes Unicode; PDF names are byte identifiers.
    // The public CGPDF name API exposes C strings, so accept its ASCII subset
    // exactly and fail closed on extension names requiring broader byte handling.
    private static func asciiName(_ pointer: UnsafePointer<CChar>) -> String? {
        guard let value = String(validatingCString: pointer), value.utf8.allSatisfy({ $0 < 128 }) else { return nil }
        return value
    }

    private static func rawValue(_ object: CGPDFObjectRef, active: inout Set<CGPDFObjectRef>,
                                 remaining: inout Int, depth: Int = 0) throws -> RawValue
    {
        let identity = object
        guard depth < 32, remaining > 0, active.insert(identity).inserted else {
            throw PDFDocumentSerializationError.invalidOutline
        }
        remaining -= 1
        defer { active.remove(identity) }
        switch CGPDFObjectGetType(object) {
        case .null: return .null
        case .boolean:
            var value: CGPDFBoolean = 0
            guard CGPDFObjectGetValue(object, .boolean, &value) else { throw PDFDocumentSerializationError.invalidOutline }
            return .boolean(value != 0)
        case .integer:
            var value: CGPDFInteger = 0
            guard CGPDFObjectGetValue(object, .integer, &value) else { throw PDFDocumentSerializationError.invalidOutline }
            return .integer(value)
        case .real:
            var value: CGPDFReal = 0
            guard CGPDFObjectGetValue(object, .real, &value), value.isFinite else { throw PDFDocumentSerializationError.invalidOutline }
            return .real(value)
        case .name:
            var value: UnsafePointer<CChar>?
            guard CGPDFObjectGetValue(object, .name, &value), let value,
                  let name = asciiName(value) else { throw PDFDocumentSerializationError.invalidOutline }
            return .name(name)
        case .string:
            var value: CGPDFStringRef?
            guard CGPDFObjectGetValue(object, .string, &value), let value else { throw PDFDocumentSerializationError.invalidOutline }
            let length = CGPDFStringGetLength(value)
            guard length > 0 else { return .string(Data()) }
            guard let bytes = CGPDFStringGetBytePtr(value) else { throw PDFDocumentSerializationError.invalidOutline }
            return .string(Data(bytes: bytes, count: length))
        case .array:
            var value: CGPDFArrayRef?
            guard CGPDFObjectGetValue(object, .array, &value), let value else { throw PDFDocumentSerializationError.invalidOutline }
            var values: [RawValue] = []
            for index in 0 ..< CGPDFArrayGetCount(value) {
                var element: CGPDFObjectRef?
                guard CGPDFArrayGetObject(value, index, &element), let element else { throw PDFDocumentSerializationError.invalidOutline }
                values.append(try rawValue(element, active: &active, remaining: &remaining, depth: depth + 1))
            }
            return .array(values)
        case .dictionary:
            var value: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(object, .dictionary, &value), let value else { throw PDFDocumentSerializationError.invalidOutline }
            guard CGPDFDictionaryGetCount(value) <= remaining else { throw PDFDocumentSerializationError.invalidOutline }
            var pairs: [(String?, CGPDFObjectRef)] = []
            withUnsafeMutablePointer(to: &pairs) { pointer in
                CGPDFDictionaryApplyFunction(value, { key, value, context in
                    context?.assumingMemoryBound(to: [(String?, CGPDFObjectRef)].self).pointee.append((PDFDocumentSerializer.asciiName(key), value))
                }, pointer)
            }
            var values: [String: RawValue] = [:]
            for (key, element) in pairs {
                guard let key, values[key] == nil else { throw PDFDocumentSerializationError.invalidOutline }
                values[key] = try rawValue(element, active: &active, remaining: &remaining, depth: depth + 1)
            }
            return .dictionary(values)
        default:
            throw PDFDocumentSerializationError.invalidOutline
        }
    }
}
