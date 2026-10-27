import AppKit
import Foundation
import ScreenCaptureKit
import Testing

/// Capture only the test process's window. macOS 14.4+ captures the composited
/// surface; older hosts retain AppKit-only coverage, not composited evidence.
@MainActor
enum NativeOwnedWindowCapture {
    private enum CaptureFailure: Error { case unavailableWindow }

    static func bitmap(_ window: NSWindow) async throws -> NSBitmapImageRep {
        let view = try #require(window.contentView?.superview ?? window.contentView)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        if #available(macOS 14.4, *) {
            let number = window.windowNumber
            for attempt in 0..<3 {
                guard window.isVisible, window.windowNumber == number else { throw CaptureFailure.unavailableWindow }
                do {
                    let available = try await SCShareableContent.currentProcess
                    let owned = try #require(available.windows.first {
                        $0.windowID == CGWindowID(number) &&
                            $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
                    })
                    let configuration = SCStreamConfiguration()
                    configuration.width = Int(view.bounds.width * 2)
                    configuration.height = Int(view.bounds.height * 2)
                    configuration.scalesToFit = true
                    configuration.captureResolution = .best
                    configuration.showsCursor = false
                    configuration.ignoreShadowsSingleWindow = true
                    configuration.includeChildWindows = false
                    return NSBitmapImageRep(cgImage: try await SCScreenshotManager.captureImage(
                        contentFilter: SCContentFilter(desktopIndependentWindow: owned), configuration: configuration))
                } catch let error as NSError where error.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" && error.code == -3811 {
                    guard attempt < 2 else { throw error }
                    // Only the documented transient internal stream failure is
                    // retried. Denied capture and every other error propagate.
                    try await Task.sleep(for: .milliseconds(attempt == 0 ? 250 : 500))
                }
            }
            throw CaptureFailure.unavailableWindow
        }
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }

    static func write(_ window: NSWindow, to destination: URL) async throws {
        let bitmap = try await bitmap(window)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: destination)
    }
}
