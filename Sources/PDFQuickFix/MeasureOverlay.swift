import AppKit
import PDFKit
import SwiftUI

enum PDFMeasureUnit: String, CaseIterable, Identifiable {
    case points
    case inches
    case millimeters

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .points:
            "pt"
        case .inches:
            "in"
        case .millimeters:
            "mm"
        }
    }

    func value(fromPoints points: Double) -> Double {
        switch self {
        case .points:
            points
        case .inches:
            points / 72.0
        case .millimeters:
            points / 72.0 * 25.4
        }
    }

    func format(_ points: Double) -> String {
        let value = value(fromPoints: points)
        switch self {
        case .points:
            return String(format: "%.1f %@", value, displayName)
        case .inches:
            return String(format: "%.2f %@", value, displayName)
        case .millimeters:
            return String(format: "%.1f %@", value, displayName)
        }
    }
}

struct PDFMeasurementReading: Equatable {
    let start: CGPoint
    let end: CGPoint

    var dxPoints: Double {
        Double(end.x - start.x)
    }

    var dyPoints: Double {
        Double(end.y - start.y)
    }

    var distancePoints: Double {
        hypot(dxPoints, dyPoints)
    }

    var angleDegrees: Double {
        atan2(dyPoints, dxPoints) * 180.0 / .pi
    }

    func summary(unit: PDFMeasureUnit) -> String {
        "\(unit.format(distancePoints)) @ \(String(format: "%.1f", angleDegrees)) deg"
    }

    func details(unit: PDFMeasureUnit) -> String {
        [
            "Distance: \(unit.format(distancePoints))",
            "X: \(unit.format(dxPoints))",
            "Y: \(unit.format(dyPoints))",
            "Angle: \(String(format: "%.1f", angleDegrees)) deg",
        ].joined(separator: "\n")
    }
}

enum PDFMeasurementCoordinateMapper {
    @MainActor
    static func reading(start: CGPoint,
                        end: CGPoint,
                        overlaySize: CGSize,
                        pdfView: PDFView?) -> PDFMeasurementReading
    {
        guard let pdfView,
              overlaySize.width > 0,
              overlaySize.height > 0,
              let startPDF = pdfPoint(for: start, overlaySize: overlaySize, pdfView: pdfView),
              let endPDF = pdfPoint(for: end, overlaySize: overlaySize, pdfView: pdfView)
        else {
            return PDFMeasurementReading(start: start, end: end)
        }
        return PDFMeasurementReading(start: startPDF, end: endPDF)
    }

    @MainActor
    private static func pdfPoint(for point: CGPoint, overlaySize: CGSize, pdfView: PDFView) -> CGPoint? {
        let bounds = pdfView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let viewX = bounds.minX + (point.x / overlaySize.width) * bounds.width
        let yFromTop = (point.y / overlaySize.height) * bounds.height
        let viewY = pdfView.isFlipped ? bounds.minY + yFromTop : bounds.maxY - yFromTop
        let viewPoint = CGPoint(x: viewX, y: viewY)

        guard let page = pdfView.page(for: viewPoint, nearest: true) else { return nil }
        return pdfView.convert(viewPoint, to: page)
    }
}

struct MeasureOverlay: View {
    @Binding var reading: PDFMeasurementReading?
    let unit: PDFMeasureUnit
    let pdfView: PDFView?

    @State private var startPoint: CGPoint?
    @State private var currentPoint: CGPoint?

    private var measurementText: String {
        return reading?.summary(unit: unit) ?? "Measure"
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
                        reading = PDFMeasurementCoordinateMapper.reading(start: value.startLocation,
                                                                         end: value.location,
                                                                         overlaySize: proxy.size,
                                                                         pdfView: pdfView)
                    }
                    .onEnded { value in
                        reading = PDFMeasurementCoordinateMapper.reading(start: value.startLocation,
                                                                         end: value.location,
                                                                         overlaySize: proxy.size,
                                                                         pdfView: pdfView)
                        startPoint = nil
                        currentPoint = nil
                    }
            )
        }
    }
}

struct MeasureInspectorPanel: View {
    @Binding var reading: PDFMeasurementReading?
    @Binding var unit: PDFMeasureUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Measure")
                .font(.headline)

            Picker("Unit", selection: $unit) {
                ForEach(PDFMeasureUnit.allCases) { unit in
                    Text(unit.displayName).tag(unit)
                }
            }
            .pickerStyle(.segmented)

            if let reading {
                measurementRow("Distance", value: unit.format(reading.distancePoints))
                measurementRow("X", value: unit.format(reading.dxPoints))
                measurementRow("Y", value: unit.format(reading.dyPoints))
                measurementRow("Angle", value: String(format: "%.1f deg", reading.angleDegrees))

                HStack {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(reading.details(unit: unit), forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }

                    Button(role: .destructive) {
                        self.reading = nil
                    } label: {
                        Label("Clear", systemImage: "xmark.circle")
                    }
                }
            } else {
                measurementRow("Distance", value: "-")
                measurementRow("X", value: "-")
                measurementRow("Y", value: "-")
                measurementRow("Angle", value: "-")
            }

            Spacer()
        }
        .padding()
    }

    private func measurementRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}
