import Darwin
import Foundation
import Testing
@testable import DBeer

private enum AgentSocketTestError: Error { case io, timeout, unexpectedEnd }

private struct AgentSocketFixture {
    let directory: String
    var path: String { directory + "/s" }

    init() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let build = repository.appendingPathComponent("build", isDirectory: true)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        directory = build.appendingPathComponent("a" + UUID().uuidString.prefix(8)).path
    }

    func remove() { try? FileManager.default.removeItem(atPath: directory) }
}

private final class AgentSocketTestPeer: @unchecked Sendable {
    let descriptor: Int32

    init(path: String, smallReceiveBuffer: Bool = false) throws {
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw AgentSocketTestError.io }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        var enabled: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout.size(ofValue: enabled)))
        if smallReceiveBuffer {
            var size: Int32 = 1_024
            _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout.size(ofValue: size)))
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(descriptor); throw AgentSocketTestError.io
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { Darwin.close(descriptor); throw AgentSocketTestError.io }
    }

    func send(_ request: AgentRequest) throws {
        var frame = try JSONEncoder().encode(request); frame.append(10)
        try sendBytes(frame)
    }

    func sendBytes(_ frame: Data) throws {
        try frame.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.send(descriptor, base.advanced(by: offset), raw.count - offset, 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw AgentSocketTestError.io }
                offset += count
            }
        }
    }

    func response() throws -> AgentResponse {
        var frame = Data()
        var byte: UInt8 = 0
        while frame.count <= AgentSocketBroker.maximumResponseBytes {
            let count = recv(descriptor, &byte, 1, 0)
            guard count > 0 else { throw AgentSocketTestError.io }
            if byte == 10 { return try JSONDecoder().decode(AgentResponse.self, from: frame) }
            frame.append(byte)
        }
        throw AgentSocketTestError.io
    }

    func hasReadableBytes() -> Bool {
        var descriptor = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        return poll(&descriptor, 1, 2_000) > 0 && descriptor.revents & Int16(POLLIN) != 0
    }

    func receiveEnd() -> Bool {
        var byte: UInt8 = 0
        return recv(descriptor, &byte, 1, 0) == 0
    }

    deinit { shutdown(descriptor, SHUT_RDWR); Darwin.close(descriptor) }
}

private func nextAgentEvent(_ stream: AsyncStream<String>) async throws -> String {
    try await withThrowingTaskGroup(of: String.self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            guard let value = await iterator.next() else { throw AgentSocketTestError.unexpectedEnd }
            return value
        }
        group.addTask { try await Task.sleep(for: .seconds(3)); throw AgentSocketTestError.timeout }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

struct AgentSocketBrokerTests {
    @Test func privateSocketExchangesOnlyTypedResponsesAndHoldsExclusiveLease() async throws {
        let fixture = try AgentSocketFixture()
        defer { fixture.remove() }
        let broker = AgentSocketBroker(path: fixture.path, onRequest: { _, request in
            AgentResponse(id: request.id, ok: true, connections: [])
        }, onDisconnect: { _ in })
        try broker.start()
        defer { broker.stop() }
        var directory = stat(), socket = stat()
        #expect(lstat(fixture.directory, &directory) == 0)
        #expect(directory.st_uid == geteuid() && directory.st_mode & 0o777 == 0o700)
        #expect(lstat(fixture.path, &socket) == 0)
        #expect(socket.st_uid == geteuid() && socket.st_mode & S_IFMT == S_IFSOCK && socket.st_mode & 0o777 == 0o600)
        let duplicate = AgentSocketBroker(path: fixture.path, onRequest: { _, request in
            AgentResponse(id: request.id, ok: false)
        }, onDisconnect: { _ in })
        #expect(throws: AgentSocketError.self) { try duplicate.start() }
        var preserved = stat()
        #expect(lstat(fixture.path, &preserved) == 0 && preserved.st_ino == socket.st_ino)
        let response = try await Task.detached {
            let peer = try AgentSocketTestPeer(path: fixture.path)
            try peer.send(AgentRequest(id: "roundtrip", method: "connections"))
            return try peer.response()
        }.value
        #expect(response.id == "roundtrip" && response.ok && response.connections?.isEmpty == true)
    }

    @Test func refusesUnsafeDirectoryAndPreservesUnexpectedSocketPath() throws {
        let fixture = try AgentSocketFixture()
        defer { fixture.remove() }
        #expect(mkdir(fixture.directory, 0o755) == 0)
        #expect(chmod(fixture.directory, 0o755) == 0)
        let broker = AgentSocketBroker(path: fixture.path, onRequest: { _, request in
            AgentResponse(id: request.id, ok: true)
        }, onDisconnect: { _ in })
        #expect(throws: AgentSocketError.self) { try broker.start() }
        #expect(chmod(fixture.directory, 0o700) == 0)
        let sentinel = Data("preserve unexpected file".utf8)
        try sentinel.write(to: URL(fileURLWithPath: fixture.path))
        #expect(throws: AgentSocketError.self) { try broker.start() }
        #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.path)) == sentinel)
    }

    @Test func refusesSymlinkDirectory() throws {
        let fixture = try AgentSocketFixture()
        defer { fixture.remove() }
        let target = fixture.directory + "-target"
        defer { try? FileManager.default.removeItem(atPath: target) }
        #expect(mkdir(target, 0o700) == 0)
        #expect(symlink(target, fixture.directory) == 0)
        let broker = AgentSocketBroker(path: fixture.path, onRequest: { _, request in
            AgentResponse(id: request.id, ok: true)
        }, onDisconnect: { _ in })
        #expect(throws: AgentSocketError.self) { try broker.start() }
        #expect(!FileManager.default.fileExists(atPath: target + "/broker.lock"))
    }

    @Test(arguments: [false, true]) func malformedAndOversizeFramesDisconnectWithoutDispatch(oversize: Bool) async throws {
        let fixture = try AgentSocketFixture()
        defer { fixture.remove() }
        let (events, continuation) = AsyncStream.makeStream(of: String.self)
        defer { continuation.finish() }
        let broker = AgentSocketBroker(path: fixture.path, onRequest: { _, request in
            continuation.yield("unexpected request")
            return AgentResponse(id: request.id, ok: true)
        }, onDisconnect: { _ in continuation.yield("disconnect") })
        try broker.start()
        defer { broker.stop() }
        let ended = try await Task.detached {
            let peer = try AgentSocketTestPeer(path: fixture.path)
            let frame = oversize ? Data(repeating: 65, count: AgentSocketBroker.maximumRequestBytes + 1) : Data("invalid JSON\n".utf8)
            try peer.sendBytes(frame)
            return peer.receiveEnd()
        }.value
        #expect(ended)
        #expect(try await nextAgentEvent(events) == "disconnect")
    }

    @Test func cancelAndDisconnectRemainLiveWhenClientDoesNotConsumeLargeResponse() async throws {
        let fixture = try AgentSocketFixture()
        defer { fixture.remove() }
        let (events, continuation) = AsyncStream.makeStream(of: String.self)
        let (clientIDs, clientContinuation) = AsyncStream.makeStream(of: UUID.self)
        defer { continuation.finish(); clientContinuation.finish() }
        let broker = AgentSocketBroker(path: fixture.path, onRequest: { clientID, request in
            clientContinuation.yield(clientID)
            continuation.yield(request.method)
            if request.method == "query" {
                return AgentResponse(id: request.id, ok: true, error: String(repeating: "x", count: 900 * 1_024))
            }
            return AgentResponse(id: request.id, ok: true)
        }, onDisconnect: { _ in continuation.yield("disconnect") })
        try broker.start()
        defer { broker.stop() }
        let peer = try await Task.detached {
            try AgentSocketTestPeer(path: fixture.path, smallReceiveBuffer: true)
        }.value
        try await Task.detached { try peer.send(AgentRequest(id: "large", method: "query")) }.value
        #expect(try await nextAgentEvent(events) == "query")
        var clientIterator = clientIDs.makeAsyncIterator()
        let clientID = try #require(await clientIterator.next())
        // poll observes that the reply writer has started, without draining it.
        let hasBytes = await Task.detached { peer.hasReadableBytes() }.value
        #expect(hasBytes)
        try await Task.detached { try peer.send(AgentRequest(id: "stop", method: "cancel")) }.value
        #expect(try await nextAgentEvent(events) == "cancel")
        broker.disconnect(clientID: clientID)
        #expect(try await nextAgentEvent(events) == "disconnect")
        let other = try await Task.detached {
            let peer = try AgentSocketTestPeer(path: fixture.path)
            try peer.send(AgentRequest(id: "other", method: "connections"))
            return try peer.response()
        }.value
        #expect(other.ok && other.id == "other")
    }
}
