import Foundation
import Testing
@testable import DBeer

/// Foundation-only DTO and original socket-frame admission; no app/window setup.
struct NativeCommandTests {
    @Test func sharedCommandsPreserveEmptyBinaryAndOriginalUnicodeArguments() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("protocol/fixtures/native-commands-v1.json"))
        let fixture = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(fixture["capability"] as? String == NativeCommand.capability)
        for raw in try #require(fixture["valid"] as? [[String: Any]]) {
            let encoded = try JSONSerialization.data(withJSONObject: raw)
            try ExactJSONKeys.validate(encoded, maximumBytes: NativeCommand.maximumBytes)
            let command = try JSONDecoder().decode(NativeCommand.self, from: encoded)
            let decoded = try JSONDecoder().decode(NativeCommand.self, from: JSONEncoder().encode(command))
            #expect(command.valid && command == decoded)
        }
        for raw in try #require(fixture["invalid"] as? [[String: Any]]) {
            #expect(throws: (any Error).self) { try JSONDecoder().decode(NativeCommand.self, from: JSONSerialization.data(withJSONObject: raw)) }
        }
        for raw in try #require(fixture["invalidJSON"] as? [String]) {
            #expect(throws: (any Error).self) {
                let encoded = Data(raw.utf8)
                try ExactJSONKeys.validate(encoded, maximumBytes: NativeCommand.maximumBytes)
                _ = try JSONDecoder().decode(NativeCommand.self, from: encoded)
            }
        }
        #expect(NativeCommand(name: "READ", arguments: [.init(kind: "text", value: "é")]) != NativeCommand(name: "READ", arguments: [.init(kind: "text", value: "e\u{0301}")]))
        for value in [String(repeating: "x", count: NativeCommand.maximumBytes), String(repeating: "\0", count: NativeCommand.maximumBytes / 6), String(repeating: "<", count: NativeCommand.maximumBytes / 6)] {
            #expect(!NativeCommand(name: "READ", arguments: [.init(kind: "text", value: value)]).valid)
        }
    }

    @Test func brokerRejectsOriginalMalformedUnicodeDuplicatesAndCrossMethodPayloads() throws {
        let valid = #"{"id":"r","method":"command","profileId":"profile","queryId":"operation","nativeCommand":{"name":"ECHO","arguments":[{"kind":"text","value":""},{"kind":"binary","value":"AP8="}]}}"#
        #expect(try AgentRequest.decode(Data(valid.utf8)).nativeCommand?.arguments.count == 2)
        for raw in [
            valid.replacingOccurrences(of: #""name":"ECHO""#, with: #""name":"ECHO","name":"WRITE""#),
            valid.replacingOccurrences(of: #""value":"""#, with: #""value":"\ud800""#),
            valid.replacingOccurrences(of: #""method":"command""#, with: #""method":"query""#),
            valid.replacingOccurrences(of: #""name":"ECHO""#, with: #""name":"ECHO","sql":"SELECT 1""#)
        ] { #expect(throws: (any Error).self) { try AgentRequest.decode(Data(raw.utf8)) } }
    }
}
