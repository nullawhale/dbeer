import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ERDiagramExportRenderer {
    static func render(_ snapshot: ERDiagramExportSnapshot, format: ERDiagramExportFormat,
                       options: ERDiagramExportOptions) throws -> Data {
        let scene = try ERDiagramExportScene.make(snapshot, options: options)
        try Task.checkCancellation()
        let data: Data
        switch format {
        case .png: data = try png(scene, scale: options.scale)
        case .pdf: data = try pdf(scene)
        case .svg: data = try svg(scene)
        }
        try Task.checkCancellation()
        guard data.count <= ERDiagramExportLimits.fileBytes else { throw ERDiagramExportFailure.tooLarge }
        return data
    }

    static func png(_ scene: ERDiagramExportScene, scale: Double) throws -> Data {
        guard scale.isFinite, scale > 0 else { throw ERDiagramExportFailure.invalid }
        let width = ceil(scene.size.width * scale), height = ceil(scene.size.height * scale)
        guard width >= 1, height >= 1, width <= Double(ERDiagramExportLimits.rasterDimension), height <= Double(ERDiagramExportLimits.rasterDimension),
              width * height <= Double(ERDiagramExportLimits.rasterPixels) else { throw ERDiagramExportFailure.tooLarge }
        try Task.checkCancellation()
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8,
                                      bytesPerRow: Int(width) * 4, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ERDiagramExportFailure.render }
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: scale, y: -scale)
        try draw(scene, context: context)
        try Task.checkCancellation()
        guard let image = context.makeImage() else { throw ERDiagramExportFailure.render }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { throw ERDiagramExportFailure.render }
        let properties: [CFString: Any] = [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGDescription: metadata(scene)]]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ERDiagramExportFailure.render }
        try Task.checkCancellation()
        guard output.length <= ERDiagramExportLimits.fileBytes else { throw ERDiagramExportFailure.tooLarge }
        return output as Data
    }

    static func pdf(_ scene: ERDiagramExportScene) throws -> Data {
        try Task.checkCancellation()
        let output = NSMutableData()
        guard let consumer = CGDataConsumer(data: output as CFMutableData) else { throw ERDiagramExportFailure.render }
        var mediaBox = CGRect(origin: .zero, size: scene.size)
        let info: [CFString: Any] = [kCGPDFContextTitle: "DBeer ER Diagram", kCGPDFContextCreator: "DBeer",
                                     kCGPDFContextSubject: metadata(scene)]
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary) else { throw ERDiagramExportFailure.render }
        context.beginPDFPage(nil)
        context.translateBy(x: 0, y: scene.size.height)
        context.scaleBy(x: 1, y: -1)
        do {
            try draw(scene, context: context)
            context.endPDFPage(); context.closePDF()
        } catch {
            context.endPDFPage(); context.closePDF(); throw error
        }
        try Task.checkCancellation()
        guard output.length <= ERDiagramExportLimits.fileBytes else { throw ERDiagramExportFailure.tooLarge }
        return output as Data
    }

    static func svg(_ scene: ERDiagramExportScene) throws -> Data {
        var output = XMLWriter()
        try output.append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
        try output.append("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"" + number(scene.size.width) + "\" height=\"" + number(scene.size.height) + "\" viewBox=\"0 0 " + number(scene.size.width) + " " + number(scene.size.height) + "\">\n")
        try output.append("<title>DBeer ER Diagram</title>\n<metadata id=\"dbeer-er-export\" data-format=\"base64-json-v1\">" + scene.originalMetadata.base64EncodedString() + "</metadata>\n")
        try output.append("<rect width=\"100%\" height=\"100%\" fill=\"" + scene.palette.background.hex + "\"/>\n")
        for (index, primitive) in scene.primitives.enumerated() {
            try Task.checkCancellation()
            switch primitive {
            case .rectangle(let rect, let radius, let fill, let stroke):
                try output.append("<rect " + attributes(rect) + " rx=\"" + number(radius) + "\" fill=\"" + fill.hex + "\"" + (stroke.map { " stroke=\"" + $0.hex + "\" stroke-width=\"1\"" } ?? "") + "/>\n")
            case .line(let points, let color, let dashed):
                try output.append("<polyline points=\"" + coordinates(points) + "\" fill=\"none\" stroke=\"" + color.hex + "\" stroke-width=\"1.5\" stroke-linejoin=\"round\"" + (dashed ? " stroke-dasharray=\"7 4\"" : "") + "/>\n")
            case .polygon(let points, let color):
                try output.append("<polygon points=\"" + coordinates(points) + "\" fill=\"" + color.hex + "\"/>\n")
            case .text(let value, let rect, let size, let bold, let mono, let color):
                let clip = "text-clip-" + String(index)
                try output.append("<defs><clipPath id=\"" + clip + "\"><rect " + attributes(rect) + "/></clipPath></defs>\n")
                let font = ERDiagramExportScene.font(size: size, bold: bold, mono: mono)
                let baseline = rect.minY + CTFontGetAscent(font)
                try output.append("<text x=\"" + number(rect.minX) + "\" y=\"" + number(baseline) + "\" font-family=\"" + (mono ? "Menlo,monospace" : "Helvetica,Arial,sans-serif") + "\" font-size=\"" + number(size) + "\" font-weight=\"" + (bold ? "600" : "400") + "\" fill=\"" + color.hex + "\" clip-path=\"url(#" + clip + ")\" xml:space=\"preserve\">" + ERDiagramExportText.xml(value) + "</text>\n")
            }
        }
        try output.append("</svg>\n")
        return Data(output.text.utf8)
    }

    static func metadata(_ scene: ERDiagramExportScene) -> String {
        "DBeerERExport/v1:" + scene.originalMetadata.base64EncodedString()
    }

    private static func draw(_ scene: ERDiagramExportScene, context: CGContext) throws {
        context.setFillColor(scene.palette.background.cgColor)
        context.fill(CGRect(origin: .zero, size: scene.size))
        for primitive in scene.primitives {
            try Task.checkCancellation()
            context.saveGState()
            switch primitive {
            case .rectangle(let rect, let radius, let fill, let stroke):
                let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
                context.setFillColor(fill.cgColor); context.addPath(path); context.fillPath()
                if let stroke { context.setStrokeColor(stroke.cgColor); context.setLineWidth(1); context.addPath(path); context.strokePath() }
            case .line(let points, let color, let dashed):
                if let first = points.first {
                    context.setStrokeColor(color.cgColor); context.setLineWidth(1.5); context.setLineJoin(.round)
                    context.setLineDash(phase: 0, lengths: dashed ? [7, 4] : [])
                    context.beginPath(); context.move(to: CGPoint(x: first.x, y: first.y))
                    for point in points.dropFirst() { context.addLine(to: CGPoint(x: point.x, y: point.y)) }
                    context.strokePath()
                }
            case .polygon(let points, let color):
                if let first = points.first {
                    context.setFillColor(color.cgColor); context.beginPath(); context.move(to: CGPoint(x: first.x, y: first.y))
                    for point in points.dropFirst() { context.addLine(to: CGPoint(x: point.x, y: point.y)) }
                    context.closePath(); context.fillPath()
                }
            case .text(let value, let rect, let size, let bold, let mono, let color):
                let font = ERDiagramExportScene.font(size: size, bold: bold, mono: mono)
                let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                               NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor]
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attributes))
                context.clip(to: rect)
                context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
                context.textPosition = CGPoint(x: rect.minX, y: rect.minY + CTFontGetAscent(font))
                CTLineDraw(line, context)
            }
            context.restoreGState()
        }
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
    private static func attributes(_ rect: CGRect) -> String {
        "x=\"" + number(rect.minX) + "\" y=\"" + number(rect.minY) + "\" width=\"" + number(rect.width) + "\" height=\"" + number(rect.height) + "\""
    }
    private static func coordinates(_ points: [ERPoint]) -> String {
        points.map { number($0.x) + "," + number($0.y) }.joined(separator: " ")
    }
    private struct XMLWriter {
        var text = ""
        var bytes = 0
        mutating func append(_ value: String) throws {
            try Task.checkCancellation()
            guard value.utf8.count <= ERDiagramExportLimits.fileBytes - bytes else { throw ERDiagramExportFailure.tooLarge }
            bytes += value.utf8.count; text += value
        }
    }
}
