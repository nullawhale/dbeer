import AppKit
import Darwin
import Foundation
import Testing

// Swift 6.2+ async-main hosts may exit(0) when AppKit stops the main run loop,
// even though tests are unfinished: https://github.com/swiftlang/swift/issues/91716.
// Keep a synchronous main alive; Swift Testing owns the final exit status.
// Pump AppKit events as well: a bare CFRunLoop cannot activate native windows
// or exercise their keyboard focus and context-menu states.
@main enum SwiftTestingHost {
    static func main() {
        guard let path = ProcessInfo.processInfo.environment["DBEER_TEST_BUNDLE_PATH"],
              dlopen(path, RTLD_NOW | RTLD_GLOBAL) != nil else {
            FileHandle.standardError.write(Data("Unable to load the native test bundle.\n".utf8))
            exit(1)
        }
        var configuration = Testing.__CommandLineArguments_v0()
        configuration.parallel = false
        var arguments = CommandLine.arguments.dropFirst().makeIterator()
        while let argument = arguments.next() {
            guard argument == "--filter", let filter = arguments.next() else {
                FileHandle.standardError.write(Data("Usage: native-test-host [--filter pattern]\n".utf8))
                exit(2)
            }
            configuration.filter = (configuration.filter ?? []) + [filter]
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let options = configuration
        Task { await Testing.__swiftPMEntryPoint(passing: options) as Never }
        while true { application.run() }
    }
}
