import Foundation
import Testing
@testable import DBeer

/// Synthetic shared codec cases; these never launch helpers or access stores.
struct GPUIProductBuildIdentityTests {
    private struct Case: Decodable { let name: String; let file: String; let valid: Bool; let canonical: String? }
    private struct Native: Decodable { let os: String; let architecture: String; let abi: String; let target: String? }
    private struct Fixtures: Decodable {
        let schemaVersion: Int
        let identityCases: [Case]
        let infoCases: [Case]
        let helloCases: [Case]
        let nativeCases: [Native]
    }
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("protocol/fixtures/gpui-build-identity-v1")
    }
    private func read(_ file: String) throws -> Data { try Data(contentsOf: root.appendingPathComponent(file)) }
    private func fixtures() throws -> Fixtures {
        let value = try JSONDecoder().decode(Fixtures.self, from: read("cases.json"))
        #expect(value.schemaVersion == 1)
        return value
    }
    @Test func sharedIdentitiesRejectMalformedAndRetainExactCanonicalBytes() throws {
        for entry in try fixtures().identityCases {
            let result = Result { try GPUIProductBuildIdentity.parse(read(entry.file)) }
            switch result {
            case .success(let identity):
                #expect(entry.valid, "\(entry.name)")
                let canonical = try read(#require(entry.canonical))
                #expect(try identity.canonicalJSON() == canonical, "\(entry.name)")
                let encoded = try JSONEncoder().encode(identity)
                #expect(try GPUIProductBuildIdentity.parse(encoded) == identity)
            case .failure: #expect(!entry.valid, "\(entry.name)")
            }
        }
    }
    @Test func originalByteOffsetsSupportNonzeroDataSliceIndices() throws {
        let raw = try read("valid-linux.json")
        let padded = Data("prefix".utf8) + raw
        #expect(try GPUIProductBuildIdentity.parse(padded.dropFirst(6)) == GPUIProductBuildIdentity.parse(raw))
        let hello = Data("prefix".utf8) + (try read("hello-linux.json"))
        #expect(try GPUIProductBuildIdentity.optionalFromHelloAck(hello.dropFirst(6)) == GPUIProductBuildIdentity.parse(raw))
    }
    @Test func sharedBuildInfoMatchesBothComponents() throws {
        for entry in try fixtures().infoCases {
            let result = Result { try GPUIProductBuildIdentity.Info.parse(read(entry.file)) }
            switch result {
            case .success(let info):
                #expect(entry.valid, "\(entry.name)")
                #expect(try info.canonicalJSON() == read(#require(entry.canonical)), "\(entry.name)")
            case .failure: #expect(!entry.valid, "\(entry.name)")
            }
        }
    }
    @Test func rawHelloPreflightPreservesOptionalMacCompatibilityAndRejectsDuplicates() throws {
        for entry in try fixtures().helloCases {
            let result = Result { try GPUIProductBuildIdentity.optionalFromHelloAck(read(entry.file)) }
            switch result {
            case .success(let identity):
                #expect(entry.valid, "\(entry.name)")
                if let canonical = entry.canonical {
                    #expect(try #require(identity).canonicalJSON() == read(canonical))
                } else { #expect(identity == nil) }
            case .failure: #expect(!entry.valid, "\(entry.name)")
            }
        }
        let frame = try read("hello-linux.json")
        #expect(throws: GPUIProductBuildIdentity.Failure.self) {
            try GPUIProductBuildIdentity.optionalFromHelloAck(frame, maximumFrameBytes: frame.count - 1)
        }
    }
    @Test func pureNativeLabelsNormalizeRustAndGoArchitectureNames() throws {
        for entry in try fixtures().nativeCases {
            #expect(GPUIProductBuildIdentity.NativeTarget.normalized(os: entry.os,
                architecture: entry.architecture, abi: entry.abi)?.rawValue == entry.target)
        }
    }
    @Test func nativeTransportUsesOriginalHelloBytesBeforeFoundationDecode() throws {
        for entry in try fixtures().helloCases {
            let result = Result { try NDJSONFramer.decode(read(entry.file)) }
            switch result {
            case .success(let reply):
                #expect(entry.valid, "\(entry.name)")
                #expect(reply.type == "hello.ack")
                if let canonical = entry.canonical {
                    #expect(try #require(reply.buildIdentity).canonicalJSON() == read(canonical))
                } else { #expect(reply.buildIdentity == nil) }
            case .failure: #expect(!entry.valid, "\(entry.name)")
            }
        }
        let raw = try read("valid-linux.json")
        let identity = String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in [String(repeating: " ", count: 4_096), "\"schemaVersion\":1,"] {
            let nested = "{" + prefix + identity.dropFirst()
            let frame = Data(("{\"type\":\"hello.ack\",\"requestId\":\"fixture\",\"protocolVersion\":3,\"buildIdentity\":" + nested + "}").utf8)
            #expect(throws: BackendTransportError.self) { try NDJSONFramer.decode(frame) }
        }
        let alias = Data("{\"type\":\"shutdown.ack\",\"ty\\u0070e\":\"hello.ack\",\"requestId\":\"fixture\",\"protocolVersion\":3}".utf8)
        #expect(throws: BackendTransportError.self) { try NDJSONFramer.decode(alias) }
        #expect(try NDJSONFramer.decode(Data("{\"type\":\"shutdown.ack\",\"requestId\":\"fixture\"}".utf8)).buildIdentity == nil)
    }
    @Test func productHandshakeRequiresExactBuildAndSemanticCapability() throws {
        let identity = try GPUIProductBuildIdentity.parse(read("valid-linux.json"))
        try identity.requireMatchingHelper(identity, protocolVersion: 3, capabilities: ["capturedExportV1"])
        let windows = try GPUIProductBuildIdentity.parse(read("valid-windows.json"))
        for remote in [nil, windows] {
            #expect(throws: GPUIProductBuildIdentity.Failure.self) {
                try identity.requireMatchingHelper(remote, protocolVersion: 3, capabilities: ["capturedExportV1"])
            }
        }
        #expect(throws: GPUIProductBuildIdentity.Failure.self) {
            try identity.requireMatchingHelper(identity, protocolVersion: 3, capabilities: [])
        }
        #expect(throws: GPUIProductBuildIdentity.Failure.self) {
            try identity.requireMatchingHelper(identity, protocolVersion: 2, capabilities: ["capturedExportV1"])
        }
    }
}
