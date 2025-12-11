import AppKit
import SwiftUI
import PDFKit

/// An AppKit-based virtualized page grid for massive documents.
/// NSCollectionView handles virtualization much better than SwiftUI's LazyVGrid for 7000+ items.
struct PageGridView: NSViewRepresentable {
    @ObservedObject var controller: StudioController
    let thumbnailSize: CGSize
    let onPageSelected: (Int) -> Void
    let onPageDoubleClick: (Int) -> Void
    
    init(
        controller: StudioController,
        thumbnailSize: CGSize = CGSize(width: 120, height: 160),
        onPageSelected: @escaping (Int) -> Void = { _ in },
        onPageDoubleClick: @escaping (Int) -> Void = { _ in }
    ) {
        self.controller = controller
        self.thumbnailSize = thumbnailSize
        self.onPageSelected = onPageSelected
        self.onPageDoubleClick = onPageDoubleClick
    }
    
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        
        let collectionView = NSCollectionView()
        collectionView.collectionViewLayout = createGridLayout()
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.delegate = context.coordinator
        collectionView.dataSource = context.coordinator
        
        collectionView.register(
            PageGridCell.self,
            forItemWithIdentifier: PageGridCell.identifier
        )
        
        scrollView.documentView = collectionView
        context.coordinator.collectionView = collectionView
        context.coordinator.scrollView = scrollView
        
        return scrollView
    }
    
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.controller = controller
        context.coordinator.thumbnailSize = thumbnailSize
        context.coordinator.onPageSelected = onPageSelected
        context.coordinator.onPageDoubleClick = onPageDoubleClick
        context.coordinator.collectionView?.reloadData()
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(
            controller: controller,
            thumbnailSize: thumbnailSize,
            onPageSelected: onPageSelected,
            onPageDoubleClick: onPageDoubleClick
        )
    }
    
    private func createGridLayout() -> NSCollectionViewFlowLayout {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: thumbnailSize.width + 20, height: thumbnailSize.height + 30)
        layout.minimumInteritemSpacing = 10
        layout.minimumLineSpacing = 10
        layout.sectionInset = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        return layout
    }
    
    // MARK: - Coordinator
    
    final class Coordinator: NSObject, NSCollectionViewDelegate, NSCollectionViewDataSource {
        var controller: StudioController
        var thumbnailSize: CGSize
        var onPageSelected: (Int) -> Void
        var onPageDoubleClick: (Int) -> Void
        weak var collectionView: NSCollectionView?
        weak var scrollView: NSScrollView?
        
        init(
            controller: StudioController,
            thumbnailSize: CGSize,
            onPageSelected: @escaping (Int) -> Void,
            onPageDoubleClick: @escaping (Int) -> Void
        ) {
            self.controller = controller
            self.thumbnailSize = thumbnailSize
            self.onPageSelected = onPageSelected
            self.onPageDoubleClick = onPageDoubleClick
        }
        
        // MARK: - NSCollectionViewDataSource
        
        func numberOfSections(in collectionView: NSCollectionView) -> Int {
            1
        }
        
        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            controller.document?.pageCount ?? 0
        }
        
        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(
                withIdentifier: PageGridCell.identifier,
                for: indexPath
            ) as! PageGridCell
            
            let pageIndex = indexPath.item
            item.configure(
                pageIndex: pageIndex,
                thumbnailSize: thumbnailSize,
                controller: controller
            )
            
            return item
        }
        
        // MARK: - NSCollectionViewDelegate
        
        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            for indexPath in indexPaths {
                onPageSelected(indexPath.item)
            }
        }
        
        func collectionView(_ cv: NSCollectionView, willDisplay item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
            // Trigger thumbnail loading when cell becomes visible
            Task { @MainActor in
                controller.ensureThumbnail(for: indexPath.item)
            }
        }
    }
}

// MARK: - PageGridCell

final class PageGridCell: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("PageGridCell")
    
    private var thumbnailImageView: NSImageView!
    private var pageLabel: NSTextField!
    private var pageIndex: Int = 0
    private weak var controller: StudioController?
    
    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = 8
        view.layer?.borderWidth = 1
        view.layer?.borderColor = NSColor.separatorColor.cgColor
        
        thumbnailImageView = NSImageView()
        thumbnailImageView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailImageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(thumbnailImageView)
        
        pageLabel = NSTextField(labelWithString: "")
        pageLabel.font = .systemFont(ofSize: 10)
        pageLabel.alignment = .center
        pageLabel.textColor = .secondaryLabelColor
        pageLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pageLabel)
        
        NSLayoutConstraint.activate([
            thumbnailImageView.topAnchor.constraint(equalTo: view.topAnchor, constant: 5),
            thumbnailImageView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 5),
            thumbnailImageView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -5),
            thumbnailImageView.bottomAnchor.constraint(equalTo: pageLabel.topAnchor, constant: -5),
            
            pageLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pageLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pageLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -5),
            pageLabel.heightAnchor.constraint(equalToConstant: 16)
        ])
    }
    
    override var isSelected: Bool {
        didSet {
            view.layer?.borderColor = isSelected
                ? NSColor.controlAccentColor.cgColor
                : NSColor.separatorColor.cgColor
            view.layer?.borderWidth = isSelected ? 2 : 1
        }
    }
    
    func configure(pageIndex: Int, thumbnailSize: CGSize, controller: StudioController) {
        self.pageIndex = pageIndex
        self.controller = controller
        
        pageLabel.stringValue = "Page \(pageIndex + 1)"
        
        // Try to get cached thumbnail
        if let snapshot = controller.virtualPageProvider.snapshot(at: pageIndex),
           let thumbnail = snapshot.thumbnail {
            thumbnailImageView.image = NSImage(cgImage: thumbnail, size: thumbnailSize)
        } else {
            // Placeholder
            thumbnailImageView.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
        }
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnailImageView.image = nil
        pageLabel.stringValue = ""
    }
}

// MARK: - SwiftUI Preview Wrapper

struct PageGridViewWrapper: View {
    @ObservedObject var controller: StudioController
    @Binding var currentPage: Int
    
    var body: some View {
        PageGridView(
            controller: controller,
            onPageSelected: { index in
                currentPage = index
                if let doc = controller.document,
                   let page = doc.page(at: index) {
                    controller.pdfView?.go(to: page)
                }
            },
            onPageDoubleClick: { index in
                // Switch to single-page view at this page
                if let doc = controller.document,
                   let page = doc.page(at: index) {
                    controller.pdfView?.go(to: page)
                }
            }
        )
        .frame(minWidth: 200, minHeight: 300)
    }
}
