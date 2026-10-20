import Darwin
import Foundation

/// JSON values stay Sendable across the pipe reader, transport actor and UI.
enum SQLLSPJSON: Codable, Equatable, Sendable {
    case object([String: SQLLSPJSON]), array([SQLLSPJSON]), string(String), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let result = try? value.decode(Bool.self) { self = .bool(result) }
        else if let result = try? value.decode(String.self) { self = .string(result) }
        else if let result = try? value.decode(Double.self) { self = .number(result) }
        else if let result = try? value.decode([String: SQLLSPJSON].self) { self = .object(result) }
        else { self = .array(try value.decode([SQLLSPJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let result): try value.encode(result)
        case .array(let result): try value.encode(result)
        case .string(let result): try value.encode(result)
        case .number(let result): try value.encode(result)
        case .bool(let result): try value.encode(result)
        case .null: try value.encodeNil()
        }
    }

    subscript(_ key: String) -> SQLLSPJSON? { if case .object(let value) = self { value[key] } else { nil } }
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var array: [SQLLSPJSON]? { if case .array(let value) = self { value } else { nil } }
    var integer: Int? {
        guard case .number(let value) = self, value.isFinite, value.rounded() == value,
              value >= Double(Int32.min), value <= Double(Int32.max) else { return nil }
        return Int(value)
    }
    static func int(_ value: Int) -> Self { .number(Double(value)) }
}

enum SQLLSPError: Error, Sendable {
    case unavailable, invalidFrame, frameTooLarge, invalidMessage, timeout, requestLimit, remoteError
}

/// Standard LSP framing. Limits apply before retaining a body or decoding JSON.
struct SQLLSPFramer: Sendable {
    static let maxFrameBytes = 4 * 1_024 * 1_024
    static let maxHeaderBytes = 8 * 1_024
    private var buffer = Data()
    private var bodyLength: Int?

    mutating func append(_ bytes: Data) throws -> [Data] {
        // The reader supplies chunks <= 16 KiB. A bounded surplus permits
        // several small frames in a read without buffering an unbounded body.
        guard bytes.count <= Self.maxFrameBytes + Self.maxHeaderBytes,
              buffer.count + bytes.count <= Self.maxFrameBytes + Self.maxHeaderBytes + 16 * 1_024 else {
            throw SQLLSPError.frameTooLarge
        }
        buffer.append(bytes)
        var frames: [Data] = []
        while true {
            if bodyLength == nil {
                guard let boundary = buffer.range(of: Data([13, 10, 13, 10])) else {
                    guard buffer.count <= Self.maxHeaderBytes else { throw SQLLSPError.invalidFrame }
                    break
                }
                guard boundary.lowerBound - buffer.startIndex <= Self.maxHeaderBytes,
                      let header = String(data: buffer[..<boundary.lowerBound], encoding: .ascii) else {
                    throw SQLLSPError.invalidFrame
                }
                var length: Int?
                for line in header.components(separatedBy: "\r\n") {
                    guard let separator = line.firstIndex(of: ":") else { throw SQLLSPError.invalidFrame }
                    let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
                    if name == "content-length" {
                        let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
                        guard length == nil, !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                              let parsed = Int(value), parsed > 0 else { throw SQLLSPError.invalidFrame }
                        guard parsed <= Self.maxFrameBytes else { throw SQLLSPError.frameTooLarge }
                        length = parsed
                    }
                }
                guard let length else { throw SQLLSPError.invalidFrame }
                bodyLength = length
                buffer.removeSubrange(..<boundary.upperBound)
            }
            guard let length = bodyLength, buffer.count >= length else { break }
            frames.append(Data(buffer.prefix(length)))
            buffer.removeFirst(length)
            bodyLength = nil
        }
        return frames
    }

    func finish() throws {
        guard buffer.isEmpty, bodyLength == nil else { throw SQLLSPError.invalidFrame }
    }

    static func encode(_ message: SQLLSPJSON) throws -> Data {
        let body = try JSONEncoder().encode(message)
        guard body.count <= maxFrameBytes else { throw SQLLSPError.frameTooLarge }
        var frame = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        frame.append(body)
        return frame
    }
}

/// FileHandle.write may block when a child stops reading. A dedicated serial
/// queue and byte budget keep that work away from both actors and bound memory.
private final class SQLLSPWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "dbeer.lsp.stdin", qos: .utility)
    private let lock = NSLock()
    private var queuedBytes = 0
    private var closing = false

    init(_ handle: FileHandle) {
        self.handle = handle
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    func enqueue(_ data: Data, onFailure: @escaping @Sendable () -> Void) throws {
        lock.lock()
        guard !closing, queuedBytes + data.count <= SQLLSPFramer.maxFrameBytes * 2 else {
            lock.unlock()
            throw SQLLSPError.unavailable
        }
        queuedBytes += data.count
        lock.unlock()
        queue.async {
            do { try self.handle.write(contentsOf: data) } catch { onFailure() }
            self.lock.lock()
            self.queuedBytes -= data.count
            self.lock.unlock()
        }
    }

    func close() {
        lock.lock()
        let wasClosing = closing
        closing = true
        lock.unlock()
        guard !wasClosing else { return }
        queue.async { try? self.handle.close() }
    }
}

/// Owns a separate helper process in language-server mode. It never connects to
/// a database; stderr is discarded rather than retaining potentially private SQL.
actor SQLLSPTransport {
    private struct Pending {
        let continuation: CheckedContinuation<SQLLSPJSON, Error>
        let timeout: Task<Void, Never>
    }

    private let executableURL: URL
    private let arguments: [String]
    private let requestTimeout: Duration
    private var process: Process?
    private var writer: SQLLSPWriter?
    private var pending: [Int: Pending] = [:]
    private var nextID = 0
    private var failed = false
    private var stopping = false
    private var shutdownTask: Task<Void, Never>?
    private var onNotification: (@Sendable (SQLLSPJSON) async -> Void)?

    init(executableURL: URL, arguments: [String] = ["--language-server"], requestTimeout: Duration = .seconds(2)) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.requestTimeout = requestTimeout
    }

    func start(onNotification: @escaping @Sendable (SQLLSPJSON) async -> Void) async throws {
        guard process == nil, !failed, !stopping,
              FileManager.default.isExecutableFile(atPath: executableURL.path) else { throw SQLLSPError.unavailable }
        self.onNotification = onNotification
        let child = Process()
        let input = Pipe()
        let output = Pipe()
        child.executableURL = executableURL
        child.arguments = arguments
        // Startup/test environments can contain database credentials. This
        // offline process needs only a fixed executable search path and locale.
        child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
        child.standardInput = input
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        child.terminationHandler = { [weak self] _ in Task { await self?.processExited() } }
        do { try child.run() } catch { failed = true; throw SQLLSPError.unavailable }
        process = child
        writer = SQLLSPWriter(input.fileHandleForWriting)
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        let handle = output.fileHandleForReading
        DispatchQueue(label: "dbeer.lsp.stdout", qos: .utility).async { [weak self] in
            defer { try? handle.close() }
            var framer = SQLLSPFramer()
            do {
                while true {
                    var bytes = [UInt8](repeating: 0, count: 16 * 1_024)
                    let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw SQLLSPError.unavailable
                    }
                    if count == 0 { break }
                    for frame in try framer.append(Data(bytes.prefix(count))) {
                        let message = try JSONDecoder().decode(SQLLSPJSON.self, from: frame)
                        // One delivery at a time bounds both actor mailbox and
                        // notification work even when the child floods stdout.
                        let delivered = DispatchSemaphore(value: 0)
                        Task { @Sendable [weak self, message, delivered] in
                            await self?.receive(message)
                            delivered.signal()
                        }
                        delivered.wait()
                    }
                }
                try framer.finish()
            } catch { /* Transport failures are deliberately content-free. */ }
            Task { @Sendable [weak self] in await self?.fail() }
        }
        do {
            _ = try await request(method: "initialize", params: .object([
                "processId": .null, "rootUri": .null,
                "capabilities": .object([
                    "general": .object(["positionEncodings": .array([.string("utf-16")])]),
                    "textDocument": .object([
                        "completion": .object(["completionItem": .object(["snippetSupport": .bool(false)])]),
                        "signatureHelp": .object(["signatureInformation": .object([
                            "parameterInformation": .object(["labelOffsetSupport": .bool(true)]),
                            "activeParameterSupport": .bool(true)
                        ])]),
                        "publishDiagnostics": .object(["versionSupport": .bool(true)])
                    ])
                ])
            ]))
            try notify(method: "initialized", params: .object([:]))
        } catch {
            fail()
            throw error
        }
    }

    func notify(method: String, params: SQLLSPJSON) throws {
        try send(.object(["jsonrpc": .string("2.0"), "method": .string(method), "params": params]))
    }

    func request(method: String, params: SQLLSPJSON, timeout: Duration? = nil) async throws -> SQLLSPJSON {
        guard !failed, writer != nil else { throw SQLLSPError.unavailable }
        guard pending.count < 32 else { throw SQLLSPError.requestLimit }
        nextID += 1
        let id = nextID
        let duration = timeout ?? requestTimeout
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let deadline = Task { [weak self] in
                    do { try await Task.sleep(for: duration) } catch { return }
                    await self?.expire(id)
                }
                pending[id] = Pending(continuation: continuation, timeout: deadline)
                do {
                    try send(.object(["jsonrpc": .string("2.0"), "id": .int(id),
                                      "method": .string(method), "params": params]))
                } catch {
                    pending.removeValue(forKey: id)?.timeout.cancel()
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: { [weak self] in Task { await self?.cancel(id) } }
    }

    func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        let task = Task { await self.performShutdown() }
        shutdownTask = task
        await task.value
    }

    private func performShutdown() async {
        stopping = true
        guard let child = process else { return }
        if child.isRunning, !failed {
            _ = try? await request(method: "shutdown", params: .null, timeout: .milliseconds(400))
            try? notify(method: "exit", params: .null)
        }
        writer?.close()
        for _ in 0..<20 where child.isRunning { try? await Task.sleep(for: .milliseconds(25)) }
        if child.isRunning { child.terminate() }
        for _ in 0..<10 where child.isRunning { try? await Task.sleep(for: .milliseconds(25)) }
        if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
        fail()
        onNotification = nil
    }

    private func send(_ message: SQLLSPJSON) throws {
        guard !failed, let writer else { throw SQLLSPError.unavailable }
        try writer.enqueue(SQLLSPFramer.encode(message)) { [weak self] in Task { await self?.fail() } }
    }

    private func receive(_ message: SQLLSPJSON) async {
        guard message["jsonrpc"]?.string == "2.0" else { fail(); return }
        if let id = message["id"]?.integer {
            guard let request = pending.removeValue(forKey: id) else { return }
            request.timeout.cancel()
            if message["error"] != nil { request.continuation.resume(throwing: SQLLSPError.remoteError) }
            else if let result = message["result"] { request.continuation.resume(returning: result) }
            else { request.continuation.resume(throwing: SQLLSPError.invalidMessage) }
        } else if message["method"]?.string != nil {
            await onNotification?(message)
        } else { fail() }
    }

    private func expire(_ id: Int) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.continuation.resume(throwing: SQLLSPError.timeout)
        try? notify(method: "$/cancelRequest", params: .object(["id": .int(id)]))
    }

    private func cancel(_ id: Int) {
        guard let request = pending.removeValue(forKey: id) else { return }
        request.timeout.cancel()
        request.continuation.resume(throwing: CancellationError())
        try? notify(method: "$/cancelRequest", params: .object(["id": .int(id)]))
    }

    private func processExited() { fail() }

    private func fail() {
        guard !failed else { return }
        failed = true
        for request in pending.values {
            request.timeout.cancel()
            request.continuation.resume(throwing: SQLLSPError.unavailable)
        }
        pending.removeAll()
        writer?.close()
        if let process, process.isRunning { process.terminate() }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            await self?.killIfRunning()
        }
        if !stopping, let onNotification {
            Task { await onNotification(.object(["method": .string("$/dbeerTransportClosed")])) }
        }
    }

    private func killIfRunning() {
        if let process, process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
    }
}
