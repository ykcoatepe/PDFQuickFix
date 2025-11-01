import SwiftUI
import AppKit

struct SignatureCaptureView: View {
    @Binding var image: NSImage?
    @State private var drawing = NSBezierPath()
    @State private var lastPoint: CGPoint? = nil
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Create your signature").font(.headline)
            ZStack {
                RoundedRectangle(cornerRadius: 8).stroke(.secondary, style: .init(lineWidth: 1, dash: [4]))
                SignatureCanvas(drawing: $drawing, lastPoint: $lastPoint)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .frame(height: 160)
            HStack {
                Button("Clear") { drawing = NSBezierPath() }
                Spacer()
                Button("Save") {
                    if let img = SignatureStore.image(from: drawing, size: CGSize(width: 800, height: 300)) {
                        self.image = img
                        SignatureStore.save(img)
                    }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(10)
    }
}

struct SignatureCanvas: NSViewRepresentable {
    @Binding var drawing: NSBezierPath
    @Binding var lastPoint: CGPoint?
    func makeNSView(context: Context) -> NSCanvasView {
        let v = NSCanvasView()
        v.drawingBinding = $drawing
        v.lastPoint = lastPoint
        return v
    }
    func updateNSView(_ nsView: NSCanvasView, context: Context) {
        nsView.drawingBinding = $drawing
    }
}

final class NSCanvasView: NSView {
    var drawingBinding: Binding<NSBezierPath> = .constant(NSBezierPath())
    var lastPoint: CGPoint? = nil
    
    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        lastPoint = pt
    }
    override func mouseDragged(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        if let last = lastPoint {
            drawingBinding.wrappedValue.move(to: last)
            drawingBinding.wrappedValue.line(to: pt)
        }
        lastPoint = pt
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        dirtyRect.fill()
        NSColor.black.setStroke()
        drawingBinding.wrappedValue.lineWidth = 2
        drawingBinding.wrappedValue.stroke()
    }
}

enum SignatureStore {
    static func appSupportURL() -> URL? {
        let fm = FileManager.default
        if let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let dir = base.appendingPathComponent("PDFQuickFix", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        return nil
    }
    static func save(_ image: NSImage) {
        guard let url = appSupportURL()?.appendingPathComponent("signature.png") else { return }
        if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: url)
        }
    }
    static func load() -> NSImage? {
        guard let url = appSupportURL()?.appendingPathComponent("signature.png"),
              let data = try? Data(contentsOf: url),
              let img = NSImage(data: data) else { return nil }
        return img
    }
    static func image(from path: NSBezierPath, size: CGSize) -> NSImage? {
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor.black.setStroke()
        path.lineWidth = 6
        path.stroke()
        img.unlockFocus()
        return img
    }
}
