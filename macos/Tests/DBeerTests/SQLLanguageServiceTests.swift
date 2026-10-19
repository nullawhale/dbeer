import Darwin
import Foundation
import Testing
@testable import DBeer

struct SQLLSPCodecTests {
    @Test func contentLengthFramesHandleSplitHeadersUnicodeAndCoalescedMessages() throws {
        let first = SQLLSPJSON.object(["jsonrpc": .string("2.0"), "id": .int(1), "result": .string("κόσμος 🌍\nSQL")])
        let second = SQLLSPJSON.object(["jsonrpc": .string("2.0"), "method": .string("initialized"), "params": .object([:])])
        let bytes = try SQLLSPFramer.encode(first) + SQLLSPFramer.encode(second)
        for size in 1...37 {
            var framer = SQLLSPFramer()
            var frames: [Data] = []
            for offset in stride(from: 0, to: bytes.count, by: size) {
                frames += try framer.append(bytes.subdata(in: offset..<min(bytes.count, offset + size)))
            }
            try framer.finish()
            #expect(try frames.map { try JSONDecoder().decode(SQLLSPJSON.self, from: $0) } == [first, second])
        }
    }

    @Test func invalidDuplicateOversizedAndIncompleteFramesAreRejected() throws {
        for header in ["Content-Length: -1", "Content-Length: 0", "Content-Length: 1\r\nContent-Length: 1", "Other: 3"] {
            var framer = SQLLSPFramer()
            #expect(throws: SQLLSPError.self) { _ = try framer.append(Data((header + "\r\n\r\n").utf8)) }
        }
        var large = SQLLSPFramer()
        #expect(throws: SQLLSPError.self) {
            _ = try large.append(Data("Content-Length: \(SQLLSPFramer.maxFrameBytes + 1)\r\n\r\n".utf8))
        }
        var header = SQLLSPFramer()
        #expect(throws: SQLLSPError.self) { _ = try header.append(Data(repeating: 65, count: SQLLSPFramer.maxHeaderBytes + 1)) }
        var incomplete = SQLLSPFramer()
        _ = try incomplete.append(Data("Content-Length: 5\r\n\r\n{}".utf8))
        #expect(throws: SQLLSPError.self) { try incomplete.finish() }
    }

    @Test func maximumBodyAllowsNextFrameInTheSamePipeRead() throws {
        let first = Data(repeating: 65, count: SQLLSPFramer.maxFrameBytes)
        let second = Data(repeating: 66, count: 16 * 1_024)
        var bytes = Data("Content-Length: \(first.count)\r\n\r\n".utf8)
        bytes.append(first)
        bytes.append(Data("Content-Length: \(second.count)\r\n\r\n".utf8))
        bytes.append(second)
        var framer = SQLLSPFramer()
        var frames: [Data] = []
        for offset in stride(from: 0, to: bytes.count, by: 16 * 1_024) {
            frames += try framer.append(bytes.subdata(in: offset..<min(bytes.count, offset + 16 * 1_024)))
        }
        try framer.finish()
        #expect(frames == [first, second])
    }

    @Test func utf16PositionsRoundTripAcrossUnicodeCRLFAndEmptyLastLine() throws {
        let text = "🌍é\r\nκείμενο\n"
        for offset in [0, 2, 3, 4, 6, 7, 13, 14] {
            let position = try #require(SQLLSPPosition.position(offset: offset, in: text))
            #expect(SQLLSPPosition.offset(position: position, in: text) == offset)
        }
        #expect(SQLLSPPosition.position(offset: 5, in: text) == nil) // Inside CRLF.
        #expect(SQLLSPPosition.position(offset: 1, in: text) == nil) // Inside a surrogate pair.
        #expect(SQLLSPPosition.offset(position: .object(["line": .int(0), "character": .int(1)]), in: text) == nil)
        #expect(SQLLSPPosition.offset(position: .object(["line": .int(0), "character": .int(50)]), in: text) == nil)
        #expect(SQLLSPPosition.offset(position: .object(["line": .int(9), "character": .int(0)]), in: text) == nil)
        let value = SQLLSPJSON.object([
            "start": .object(["line": .int(1), "character": .int(0)]),
            "end": .object(["line": .int(1), "character": .int(7)])
        ])
        #expect(SQLLSPPosition.range(value, in: text) == NSRange(location: 6, length: 7))
    }
}

@MainActor
struct SQLLanguageServiceTests {
    private func helper(completion: String) -> SQLLanguageService {
        let program = """
        import json, sys, time
        documents = {}
        contexts = {}
        configurations = 0
        def read():
            length = None
            while True:
                line = sys.stdin.buffer.readline()
                if not line:
                    return None
                if line == b'\\r\\n':
                    break
                if line.lower().startswith(b'content-length:'):
                    length = int(line.split(b':', 1)[1])
            return json.loads(sys.stdin.buffer.read(length))
        def send(value):
            body = json.dumps(value, ensure_ascii=False).encode('utf-8')
            sys.stdout.buffer.write(('Content-Length: %d\\r\\n\\r\\n' % len(body)).encode() + body)
            sys.stdout.buffer.flush()
        def result(command, value):
            send({'jsonrpc':'2.0', 'id':command['id'], 'result':value})
        def complete(command):
        \(completion.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n"))
        while True:
            command = read()
            if command is None:
                break
            method = command['method']
            params = command.get('params') or {}
            if method == 'initialize':
                sys.stderr.write('x' * 262144)
                sys.stderr.flush()
                result(command, {'capabilities':{'textDocumentSync':1, 'completionProvider':{}}})
            elif method == 'workspace/didChangeConfiguration':
                context = params['settings']['dbeer']
                contexts[context['uri']] = context
                configurations += 1
            elif method == 'textDocument/didOpen':
                document = params['textDocument']
                documents[document['uri']] = document.copy()
            elif method == 'textDocument/didChange':
                document = documents[params['textDocument']['uri']]
                document.update(params['textDocument'])
                document['text'] = params['contentChanges'][0]['text']
            elif method == 'textDocument/didClose':
                uri = params['textDocument']['uri']
                documents.pop(uri, None)
                contexts.pop(uri, None)
            elif method == 'textDocument/completion':
                complete(command)
            elif method == 'shutdown':
                result(command, None)
            elif method == 'exit':
                break
        """
        return SQLLanguageService(helperURL: URL(fileURLWithPath: "/usr/bin/python3"),
                                  helperArguments: ["-u", "-c", program], requestTimeout: .seconds(1))
    }

    @Test func replacementRangeUsesUTF16AndCatalogIsNotResentForTyping() async throws {
        let service = helper(completion: """
        uri = command['params']['textDocument']['uri']
        result(command, [{'label':'name','insertText':'ignored','detail':str(configurations), 'kind':5,
                          'textEdit':{'range':{'start':{'line':1,'character':7},'end':{'line':1,'character':9}},'newText':'"name"'}}])
        """)
        let id = UUID()
        let text = "SELECT '🌍';\nSELECT na"
        service.update(documentID: id, text: text, engine: .postgresql, context: .empty)
        let first = await service.completion(documentID: id, offset: text.utf16.count)
        #expect(service.isAvailable)
        #expect(first.first?.replacement == "\"name\"")
        #expect(first.first?.replacementRange == NSRange(location: text.utf16.count - 2, length: 2))
        #expect(first.first?.detail == "1")
        service.update(documentID: id, text: text + "m", engine: .postgresql, context: .empty)
        let second = await service.completion(documentID: id, offset: text.utf16.count + 1)
        #expect(second.first?.detail == "1")
        await service.shutdown()
        #expect(!service.isAvailable)
    }

    @Test func languageServerDoesNotInheritApplicationCredentials() async {
        let variable = "DBEER_LSP_TEST_SECRET_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        #expect(setenv(variable, "synthetic-language-server-sentinel", 1) == 0)
        defer { unsetenv(variable) }
        #expect(getenv(variable) != nil)
        let service = helper(completion: """
        import os
        private_names = ['\(variable)', 'HOME', 'PGPASSWORD', 'DBEER_TEST_DSN', 'DBEER_TEST_MYSQL_PASSWORD']
        clean = not any(name in os.environ for name in private_names)
        result(command, [{'label':'clean' if clean else 'inherited'}])
        """)
        let id = UUID()
        service.update(documentID: id, text: "SEL", engine: .postgresql, context: .empty)
        let completions = await service.completion(documentID: id, offset: 3)
        #expect(completions.map(\.label) == ["clean"])
        await service.shutdown()
    }

    @Test func profileOrCatalogChangeDiscardsInflightCompletionAndOldDiagnostics() async throws {
        for changeProfile in [true, false] {
            let service = helper(completion: """
            uri = command['params']['textDocument']['uri']
            doc = documents[uri]
            diagnostics = {'jsonrpc':'2.0','method':'textDocument/publishDiagnostics',
                           'params':{'uri':uri,'version':doc['version'],'diagnostics':[{'message':'started','severity':2,
                                     'range':{'start':{'line':0,'character':0},'end':{'line':0,'character':1}}}]}}
            send(diagnostics)
            time.sleep(0.15)
            result(command, [{'label':'stale','insertText':'stale'}])
            send(diagnostics)
            """)
            let id = UUID()
            var context = SQLCompletionContext(profileID: UUID(), catalog: [])
            var received = false
            let observer = service.addDiagnosticsObserver { documentID, diagnostics in
                if documentID == id, !diagnostics.isEmpty { received = true }
            }
            service.update(documentID: id, text: "SELECT n", engine: .postgresql, context: context)
            let completion = Task { await service.completion(documentID: id, offset: 8) }
            for _ in 0..<100 where !received { try await Task.sleep(for: .milliseconds(10)) }
            #expect(received)
            if changeProfile { context.profileID = UUID() }
            else { context.catalog = [SQLCompletionRelation(schema: "public", name: "new_table", kind: "table")] }
            service.update(documentID: id, text: "SELECT n", engine: .postgresql, context: context)
            #expect(await completion.value.isEmpty)
            try await Task.sleep(for: .milliseconds(30))
            #expect(service.diagnostics(documentID: id).isEmpty)
            service.removeDiagnosticsObserver(observer)
            await service.shutdown()
        }
    }

    @Test func unavailableOrUnresponsiveServiceReturnsWithoutBlockingEditor() async throws {
        let missing = SQLLanguageService(helperURL: URL(fileURLWithPath: "/missing/dbeer-core"))
        let id = UUID()
        missing.update(documentID: id, text: "SEL", engine: .postgresql, context: .empty)
        #expect(await missing.completion(documentID: id, offset: 3).isEmpty)
        #expect(!missing.isAvailable)
        await missing.shutdown()
        let slow = helper(completion: "time.sleep(10)")
        slow.update(documentID: id, text: "SEL", engine: .postgresql, context: .empty)
        let clock = ContinuousClock()
        let start = clock.now
        #expect(await slow.completion(documentID: id, offset: 3).isEmpty)
        #expect(clock.now - start < .seconds(3))
        #expect(!slow.isAvailable)
        await slow.shutdown()
    }

    @Test func loadedCatalogIsBoundedBeforeSerialization() throws {
        let repeated = SQLCompletionRelation(schema: "public", name: "items", kind: "table",
                                             columns: Array(repeating: "column", count: 40_000))
        let catalog = SQLLanguageService.boundedCatalog(Array(repeating: repeated, count: 2_100))
        #expect(catalog.count == 2_048)
        #expect(catalog.reduce(0) { $0 + ($1["columns"]?.array?.count ?? 0) } == 32_768)
        #expect(try JSONEncoder().encode(SQLLSPJSON.array(catalog)).count < SQLLSPFramer.maxFrameBytes)
        #expect(SQLLanguageService.boundedCatalog([SQLCompletionRelation(schema: "", name: "", kind: "unknown")]).isEmpty)
    }

    @Test func realBundledLanguageServerSupportsLoadedCatalogAndDiagnostics() async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let executable = repository.appendingPathComponent("build/DBeer.app/Contents/Helpers/dbeer-core")
        try #require(FileManager.default.isExecutableFile(atPath: executable.path), "Run scripts/build-app.sh first.")
        let service = SQLLanguageService(helperURL: executable)
        let id = UUID()
        let text = "SELECT '🌍';\nSELECT u.na FROM public.users AS u"
        let context = SQLCompletionContext(profileID: UUID(), catalog: [
            SQLCompletionRelation(schema: "public", name: "users", kind: "table", columns: ["id", "name"])
        ])
        service.update(documentID: id, text: text, engine: .postgresql, context: context)
        let prefix = (text as NSString).range(of: "u.na")
        let items = await service.completion(documentID: id, offset: NSMaxRange(prefix))
        #expect(service.isAvailable)
        #expect(items.contains { $0.label == "name" && $0.replacementRange == NSRange(location: prefix.location + 2, length: 2) })
        service.update(documentID: id, text: "SELECT 'unterminated", engine: .postgresql, context: context)
        for _ in 0..<100 where service.diagnostics(documentID: id).isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(service.diagnostics(documentID: id).contains { $0.message.lowercased().contains("unterminated") || $0.range.length > 0 })
        service.close(documentID: id)
        #expect(service.diagnostics(documentID: id).isEmpty)
        await service.shutdown()
        #expect(!service.isAvailable)
    }
}
