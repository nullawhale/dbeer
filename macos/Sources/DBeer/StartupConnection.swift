import Darwin
import Foundation

/// An explicit, one-shot launch channel. Credentials never enter arguments,
/// environment variables, logs, or files; ordinary launches do not read stdin.
enum StartupConnection {
    static let maxInputBytes = 64 * 1_024

    enum InputError: LocalizedError, Sendable {
        case invalid

        var errorDescription: String? {
            "Startup connection settings could not be read. Enter the connection details and connect."
        }
    }

    static func load(
        arguments: [String],
        read: @escaping @Sendable () throws -> Data = { try readInput(from: STDIN_FILENO) }
    ) async -> Result<ConnectionSettings, InputError>? {
        guard arguments.dropFirst().contains("--connect-stdin") else { return nil }
        return await Task.detached {
            do { return .success(try decode(read())) }
            catch { return .failure(.invalid) }
        }.value
    }

    static func decode(_ data: Data) throws -> ConnectionSettings {
        guard !data.isEmpty, data.count <= maxInputBytes,
              let settings = try? JSONDecoder().decode(ConnectionSettings.self, from: data),
              settings.hasValidNativeFields else {
            throw InputError.invalid
        }
        return settings
    }

    /// Takes ownership of the descriptor and waits at most five seconds for EOF.
    /// The bounded poll/read loop runs off the main actor, even for a stalled pipe.
    static func readInput(from descriptor: Int32, timeoutMilliseconds: Int = 5_000) throws -> Data {
        defer { Darwin.close(descriptor) }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, timeoutMilliseconds)) * 1_000_000
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { throw InputError.invalid }
            let remaining = Int32(min(UInt64(Int32.max), (deadline - now + 999_999) / 1_000_000))
            var descriptorState = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&descriptorState, 1, remaining)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0, descriptorState.revents & Int16(POLLIN | POLLHUP) != 0 else {
                throw InputError.invalid
            }
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw InputError.invalid }
            if count == 0 { return data }
            guard data.count + count <= maxInputBytes else { throw InputError.invalid }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
}
