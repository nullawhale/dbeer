import Foundation

/// Tuning authority belongs to the ordinary physical owner, never a saved capture.
enum TuningTransportAdmission {
    static func validOwner(support: ExplainSupport?, engine: DatabaseEngine?, capabilities: Set<String>, helperSupports: Bool) -> Bool {
        guard helperSupports, capabilities.contains(TuningInspectRequest.capability), let support, support.valid,
              support.engine == engine, support.modes.contains(.plan) else { return false }
        if support.engine == .postgresql {
            guard support.serverVersion.range(of: #"^[0-9]+\.[0-9]+"#, options: .regularExpression) != nil,
                  let major = Int(support.serverVersion.split(separator: ".").first ?? "") else { return false }
            return major >= 14
        }
        if support.engine == .mariadb {
            guard let range = support.serverVersion.range(of: #"^(?:5\.5\.5-)?(10\.11\.[0-9]+|11\.4\.[0-9]+)-MariaDB(?:[-+][A-Za-z0-9._+~:-]+)?$"#, options: .regularExpression) else { return false }
            let version = String(support.serverVersion[range]).replacingOccurrences(of: "5.5.5-", with: "").split(separator: "-")[0].split(separator: ".").compactMap { Int($0) }
            return version.count == 3 && (version[0] == 10 ? version[2] >= 9 : version[2] >= 3)
        }
        guard support.engine == .mysql,
              support.serverVersion.range(of: #"^[1-9][0-9]*\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-(?:standard|commercial)(?:-debug)?|-debug)?$"#, options: .regularExpression) != nil else { return false }
        let components = support.serverVersion.split(separator: "-")[0].split(separator: ".").compactMap { Int($0) }
        return components.count == 3 && !components.lexicographicallyPrecedes([8, 0, 30])
    }

    static func exact<T: Encodable>(_ value: T) -> Data? {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(value)
    }
    static func settingSQL(_ value: Int) -> String { "SET LOCAL work_mem = '\(value)kB'" }
    static func optimizerSQL(_ setting: MariaDBOptimizerVariant, sql: String) -> String {
        "SET STATEMENT optimizer_switch='index_condition_pushdown=\(setting.indexConditionPushdown ? "on" : "off")' FOR\n" + sql
    }

    static func validateFrame(_ frame: Data) throws {
        guard let fields = try JSONSerialization.jsonObject(with: frame) as? [String: Any], let type = fields["type"] as? String else { return }
        let payload: String
        switch type {
        case "tuning.inspect.result": payload = "tuningInspection"
        case "tuning.validate.result": payload = "tuningValidation"
        case "tuning.setting.observe.result": payload = "tuningSettingObservation"
        case "tuning.setting.result": payload = "tuningSetting"
        default:
            if ["tuningInspection", "tuningValidation", "tuningSettingObservation", "tuningSetting"].contains(where: { fields.keys.contains($0) }) {
                throw BackendTransportError(.invalidMessage)
            }
            return
        }
        try ExactJSONKeys.validate(frame, maximumBytes: BackendProtocol.maxFrameBytes)
        let required: Set<String> = ["type", "requestId", "sessionId", "queryId", "transactionStatus", payload]
        guard Set(fields.keys) == required, !fields.values.contains(where: { $0 is NSNull }) else { throw BackendTransportError(.invalidMessage) }
    }

    static func validateCommand(_ command: BackendCommand, owner: ExplainSupport, transaction: TransactionStatus?) throws {
        guard let session = command.sessionId, BackendMessage.validID(session), command.queryId.map(BackendMessage.validID) == true else { throw BackendRequestError.invalidCommand }
        let payload: String
        switch command.type {
        case "tuning.inspect":
            payload = "tuningInspect"
            guard let request = command.tuningInspect, request.valid, request.source.context?.sessionId == session,
                  transaction == .idle, request.capture.support == owner,
                  request.source.context?.transactionStatus == transaction?.rawValue else { throw BackendRequestError.invalidCommand }
        case "tuning.validate":
            payload = "tuningValidation"
            guard let request = command.tuningValidation, request.valid, request.original.context?.sessionId == session,
                  request.mariaDBOptimizer == nil || owner.engine == .mariadb,
                  transaction == .idle, request.original.context?.transactionStatus == transaction?.rawValue,
                  command.authorization.map(BackendMessage.validID) == true else { throw BackendRequestError.invalidCommand }
        case "tuning.setting.observe":
            payload = "tuningSettingObservation"
            guard owner.engine == .postgresql, transaction == .transaction,
                  let request = command.tuningSettingObservation, request.valid, request.context.sessionId == session else { throw BackendRequestError.invalidCommand }
        case "tuning.setting":
            payload = "tuningSetting"
            guard owner.engine == .postgresql, transaction == .transaction,
                  let request = command.tuningSetting, request.valid, request.context.sessionId == session,
                  command.authorization.map(BackendMessage.validID) == true else { throw BackendRequestError.invalidCommand }
        default: throw BackendRequestError.invalidCommand
        }
        let fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(command)) as? [String: Any] ?? [:]
        var allowed: Set<String> = ["type", "requestId", "sessionId", "queryId", payload]
        if ["tuning.validate", "tuning.setting"].contains(command.type) { allowed.insert("authorization") }
        guard Set(fields.keys) == allowed else { throw BackendRequestError.invalidCommand }
    }

    static func validateOperation(_ operation: OperationRequest, session: String, owner: ExplainSupport, transaction: TransactionStatus?) throws {
        let expected: Set<String>
        if let request = operation.tuningValidation {
            guard operation.type == "tuning.validate", request.valid, transaction == .idle,
                  request.mariaDBOptimizer == nil || owner.engine == .mariadb,
                  request.original.context?.sessionId == session else { throw BackendRequestError.invalidCommand }
            expected = ["type", "tuningValidation"]
        } else if let request = operation.tuningSetting {
            guard operation.type == "tuning.setting", request.valid, transaction == .transaction,
                  owner.engine == .postgresql, request.context.sessionId == session else { throw BackendRequestError.invalidCommand }
            expected = ["type", "tuningSetting"]
        } else { throw BackendRequestError.invalidCommand }
        let fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(operation)) as? [String: Any] ?? [:]
        guard Set(fields.keys) == expected else { throw BackendRequestError.invalidCommand }
    }

    static func validateReply(_ reply: BackendMessage, command: BackendCommand, owner: ExplainSupport) throws {
        guard reply.type != "error" else { return }
        guard reply.sessionId == command.sessionId, reply.queryId == command.queryId else { throw BackendTransportError(.invalidMessage) }
        if let request = command.tuningInspect, let inspection = reply.tuningInspection {
            guard inspection.engine == owner.engine.rawValue, inspection.serverVersion.utf8.elementsEqual(owner.serverVersion.utf8),
                  inspection.target == request.target, inspection.variants.allSatisfy({ variant in
                      var expected = request.source
                      expected.sql = variant.request.sql; expected.mode = .plan
                      expected.context?.rangeLength = expected.sql.utf16.count
                      return exact(expected) == exact(variant.request)
                  }) else { throw BackendTransportError(.invalidMessage) }
        }
        if let request = command.tuningValidation, let result = reply.tuningValidation {
            guard result.originalRows <= request.maxRows, result.variantRows <= request.maxRows,
                  result.comparedBytes <= request.maxBytes else { throw BackendTransportError(.invalidMessage) }
        }
        if let request = command.tuningSetting, let result = reply.tuningSetting {
            var expected = request; expected.valueKiB = request.expectedValueKiB; expected.expectedValueKiB = request.valueKiB
            guard exact(result.restore) == exact(expected), result.beforeKiB == request.expectedValueKiB,
                  result.requestedKiB == request.valueKiB else { throw BackendTransportError(.invalidMessage) }
        }
    }
}

/// Actor-local one-use grants bind every byte of the exact operation and owner.
struct TuningGrantLedger {
    struct Grant { let session: String; let binding: Data }
    private var grants: [String: Grant] = [:]
    private var generations: [String: UUID] = [:]
    mutating func retire(_ session: String) { grants = grants.filter { $0.value.session != session }; generations[session] = UUID() }
    mutating func begin(_ session: String) -> UUID {
        retire(session)
        return generations[session]!
    }
    mutating func record(_ authorization: String, session: String, operation: OperationRequest, assessedGeneration: UUID? = nil) {
        guard assessedGeneration == nil || generations[session] == assessedGeneration else { return }
        grants = grants.filter { $0.value.session != session }
        if let binding = TuningTransportAdmission.exact(operation) { grants[authorization] = .init(session: session, binding: binding) }
    }
    mutating func consume(_ authorization: String?, session: String, operation: OperationRequest) -> Bool {
        guard let authorization, let grant = grants.removeValue(forKey: authorization), grant.session == session else { return false }
        return grant.binding == TuningTransportAdmission.exact(operation)
    }
}
