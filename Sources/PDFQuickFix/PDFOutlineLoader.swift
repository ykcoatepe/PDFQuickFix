import Foundation
@preconcurrency import PDFKit

struct OutlineLoadResult {
    let rows: [OutlineRow]
    let isTruncated: Bool
}

enum PDFOutlineLoader {
    static let massiveDocumentRowLimit = 500

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
        var didHitLimit = false

        func append(_ item: PDFOutline, depth: Int) {
            guard rows.count < maxRows else {
                didHitLimit = true
                return
            }

            rows.append(OutlineRow(outline: item, depth: depth))
            for childIndex in 0 ..< item.numberOfChildren {
                guard let child = item.child(at: childIndex) else { continue }
                append(child, depth: depth + 1)
                if didHitLimit { return }
            }
        }

        for childIndex in 0 ..< root.numberOfChildren {
            guard let child = root.child(at: childIndex) else { continue }
            append(child, depth: 0)
            if didHitLimit { break }
        }

        return OutlineLoadResult(rows: rows, isTruncated: didHitLimit)
    }
}
