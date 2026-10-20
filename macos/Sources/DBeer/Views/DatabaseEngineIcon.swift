import AppKit
import SwiftUI

struct DatabaseEngineIcon: View {
    let engine: DatabaseEngine
    var size: CGFloat = 20
    var contentInset: CGFloat = 0

    static func resourceURL(for engine: DatabaseEngine) -> URL? {
        Bundle.module.url(forResource: "\(engine.rawValue)-logo", withExtension: "svg")
    }

    private static let images: [DatabaseEngine: NSImage] = Dictionary(uniqueKeysWithValues:
        DatabaseEngine.allCases.compactMap { engine in
            guard let url = resourceURL(for: engine),
                  let image = NSImage(contentsOf: url) else { return nil }
            return (engine, image)
        })

    var body: some View {
        Image(nsImage: sizedImage)
            .renderingMode(.original)
            .resizable().scaledToFit().frame(width: canvasSize, height: canvasSize)
            .accessibilityLabel(engine.displayName)
    }

    private var sizedImage: NSImage {
        let image = Self.images[engine]?.copy() as? NSImage ?? NSImage(systemSymbolName: "cylinder.split.1x2", accessibilityDescription: engine.displayName) ?? NSImage()
        // Native menu labels use NSImage's intrinsic size instead of SwiftUI's frame.
        image.size = NSSize(width: size, height: size)
        guard contentInset > 0 else { return image }
        let inset = contentInset
        return NSImage(size: NSSize(width: canvasSize, height: canvasSize), flipped: false) { rect in
            image.draw(in: rect.insetBy(dx: inset, dy: inset), from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
    }

    private var canvasSize: CGFloat { size + contentInset * 2 }
}
