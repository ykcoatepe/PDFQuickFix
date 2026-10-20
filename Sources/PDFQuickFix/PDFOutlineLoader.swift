import Foundation
@preconcurrency import PDFKit

struct OutlineLoadResult {
    let rows: [OutlineRow]
    let isTruncated: Bool
}

enum PDFOutlineLoader {
    static func rows(from root: PDFOutline?, limit: Int? = nil) -> OutlineLoadResult {
        guard let root else {
            return OutlineLoadResult(rows: [], isTruncated: false)
        }

        let maxRows = limit ?? Int.max
        guard maxRows > 0 else {
            return OutlineLoadResult(rows: [], isTruncated: root.numberOfChildren > 0)
        }

        var rows: [OutlineRow] = []
        rows.reserveCapacity(min(maxRows, max(root.numberOfChildren, 0)))
        var visited: Set<ObjectIdentifier> = [ObjectIdentifier(root)]
        var isTruncated = false
        // Retain one cursor per ancestor instead of recursing on PDF-controlled
        // depth. Visiting children in ascending order preserves depth-first rows.
        var ancestors: [(parent: PDFOutline, nextChild: Int, childDepth: Int)] = [(root, 0, 0)]
        while !ancestors.isEmpty {
            let index = ancestors.count - 1
            let cursor = ancestors[index]
            guard cursor.nextChild < cursor.parent.numberOfChildren else {
                ancestors.removeLast()
                continue
            }
            ancestors[index].nextChild += 1
            guard let child = cursor.parent.child(at: cursor.nextChild) else { continue }
            guard visited.insert(ObjectIdentifier(child)).inserted else {
                // Malformed cyclic/shared edges cannot yield a complete tree,
                // but must not prevent valid later siblings from being loaded.
                isTruncated = true
                continue
            }
            // Only a real additional row makes an exact explicit limit truncated.
            guard rows.count < maxRows else {
                return OutlineLoadResult(rows: rows, isTruncated: true)
            }
            rows.append(OutlineRow(outline: child, depth: cursor.childDepth))
            ancestors.append((child, 0, cursor.childDepth + 1))
        }

        return OutlineLoadResult(rows: rows, isTruncated: isTruncated)
    }
}
