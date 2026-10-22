import AppKit
import Foundation

/// Launch the exact signed fixture through LaunchServices, as Finder does.
/// Only the data-directory environment is isolated; HOME and user settings stay intact.
@main
@MainActor
struct SSHApplicationLauncher {
    private struct Configuration: Decodable {
        let appPath: String
        let dataHome: String
        let resultFile: String
    }

    private struct Result: Encodable {
        let pid: Int32
        let appPath: String
    }

    private enum Failure: Error { case invalidConfiguration, unexpectedApplication, invalidLaunch }

    static func main() {
        do {
            guard CommandLine.arguments.count == 2 else { throw Failure.invalidConfiguration }
            let url = URL(fileURLWithPath: CommandLine.arguments[1])
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
                  ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777) & 0o077 == 0 else {
                throw Failure.invalidConfiguration
            }
            let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url))
            guard config.appPath.hasPrefix("/"), config.dataHome.hasPrefix("/"), config.resultFile.hasPrefix("/"),
                  ![config.appPath, config.dataHome, config.resultFile].contains(where: { $0.contains("\0") }) else {
                throw Failure.invalidConfiguration
            }
            let appURL = URL(fileURLWithPath: config.appPath, isDirectory: true).resolvingSymlinksInPath()
            guard Bundle(url: appURL)?.bundleIdentifier == "dev.dbeer.app",
                  FileManager.default.isExecutableFile(atPath: appURL.appendingPathComponent("Contents/MacOS/DBeer").path),
                  NSWorkspace.shared.runningApplications.allSatisfy({ $0.bundleIdentifier != "dev.dbeer.app" || $0.isTerminated }) else {
                throw Failure.unexpectedApplication
            }
            let allowed = Set(["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "SHELL", "__CF_USER_TEXT_ENCODING"])
            var environment = ProcessInfo.processInfo.environment.filter { allowed.contains($0.key) }
            environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
            environment["CFFIXED_USER_HOME"] = config.dataHome
            let launch = NSWorkspace.OpenConfiguration()
            launch.environment = environment
            launch.createsNewApplicationInstance = true
            launch.activates = true
            launch.arguments = []
            NSWorkspace.shared.openApplication(at: appURL, configuration: launch) { application, error in
                do {
                    guard error == nil, let application,
                          application.bundleURL?.resolvingSymlinksInPath() == appURL else { throw Failure.invalidLaunch }
                    let data = try JSONEncoder().encode(Result(pid: application.processIdentifier, appPath: appURL.path))
                    let resultURL = URL(fileURLWithPath: config.resultFile)
                    try data.write(to: resultURL, options: [.atomic])
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: resultURL.path)
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data("SSH fixture LaunchServices launch failed.\n".utf8))
                    exit(1)
                }
            }
            RunLoop.main.run(until: Date().addingTimeInterval(30))
            throw Failure.invalidLaunch
        } catch {
            FileHandle.standardError.write(Data("SSH fixture LaunchServices launcher failed.\n".utf8))
            exit(1)
        }
    }
}
