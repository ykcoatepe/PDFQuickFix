import SwiftUI

struct MeasureOverlay: View {
    @State private var startPoint: CGPoint?
    @State private var currentPoint: CGPoint?

    private var measurementText: String {
        guard let start = startPoint, let end = currentPoint else {
            return "Click and drag to measure distances."
        }
        let dx = Double(end.x - start.x)
        let dy = Double(end.y - start.y)
        let distance = hypot(dx, dy)
        let inches = distance / 72.0
        let mm = inches * 25.4
        return String(format: "Δx %.1f pt • Δy %.1f pt • %.2f in / %.1f mm",
                      dx, dy, inches, mm)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Color.clear
                if let start = startPoint, let end = currentPoint {
                    Path { path in
                        path.move(to: start)
                        path.addLine(to: end)
                    }
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 6]))

                    let rect = CGRect(x: min(start.x, end.x),
                                      y: min(start.y, end.y),
                                      width: abs(end.x - start.x),
                                      height: abs(end.y - start.y))

                    Rectangle()
                        .stroke(Color.accentColor.opacity(0.4), lineWidth: 1)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }

                Text(measurementText)
                    .font(.caption.monospacedDigit())
                    .padding(8)
                    .background(.thinMaterial)
                    .cornerRadius(6)
                    .padding()
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if startPoint == nil {
                            startPoint = value.startLocation
                        }
                        currentPoint = value.location
                    }
                    .onEnded { _ in
                        startPoint = nil
                        currentPoint = nil
                    }
            )
        }
    }
}
