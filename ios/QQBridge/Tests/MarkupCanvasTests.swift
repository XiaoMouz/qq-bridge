import PencilKit
import Testing
import UIKit
@testable import BetterChat

@Suite(.serialized) @MainActor
struct MarkupCanvasTests {
  @Test func resizingKeepsDrawingAndExportAligned() throws {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let image = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 600), format: format).image { context in
      UIColor.white.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 400, height: 600))
    }
    let canvas = MarkupCanvasView(frame: CGRect(x: 0, y: 0, width: 200, height: 300))
    canvas.imageSize = image.size
    let points = [CGPoint(x: 120, y: 200), CGPoint(x: 350, y: 500)].enumerated().map { index, point in
      PKStrokePoint(location: point, timeOffset: Double(index), size: CGSize(width: 16, height: 16),
        opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
    }
    canvas.drawing = PKDrawing(strokes: [
      PKStroke(ink: PKInk(.pen, color: .red), path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0)))
    ])
    canvas.layoutIfNeeded()
    let originalDrawing = canvas.drawing.dataRepresentation()
    let export = try #require(canvas.renderedImage(over: image))
    #expect(export.size == image.size)
    #expect(export.pngData() != image.pngData())
    for size in [CGSize(width: 360, height: 540), CGSize(width: 160, height: 240)] {
      canvas.frame.size = size
      canvas.setNeedsLayout()
      canvas.layoutIfNeeded()
      #expect(canvas.drawing.dataRepresentation() == originalDrawing)
      #expect(canvas.renderedImage(over: image)?.pngData() == export.pngData())
    }
  }
}
