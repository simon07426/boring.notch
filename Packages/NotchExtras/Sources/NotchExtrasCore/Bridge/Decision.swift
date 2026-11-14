import Foundation

public struct DecisionQuestion: Codable, Equatable, Sendable {
    public struct Option: Codable, Equatable, Sendable {
        public var label: String
        public var description: String?
        public init(label: String, description: String? = nil) {
            self.label = label
            self.description = description
        }
    }

    public var question: String
    public var header: String?
    public var options: [Option]
    public var multiSelect: Bool

    public init(question: String, header: String? = nil, options: [Option], multiSelect: Bool = false) {
        self.question = question
        self.header = header
        self.options = options
        self.multiSelect = multiSelect
    }
}

public struct DecisionRequest: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case permission
        case question
    }

    public var session: String
    public var kind: Kind
    public var project: String?
    public var question: String
    public var command: String?
    public var explain: String?
    public var questions: [DecisionQuestion]?

    public init(session: String, kind: Kind, project: String? = nil, question: String,
                command: String? = nil, explain: String? = nil, questions: [DecisionQuestion]? = nil) {
        self.session = session
        self.kind = kind
        self.project = project
        self.question = question
        self.command = command
        self.explain = explain
        self.questions = questions
    }
}

public enum DecisionStatus: Equatable, Sendable {
    case pending
    case allow
    case deny
    case answered([String: String])
    case withdrawn
    case gone

    var wireName: String {
        switch self {
        case .pending: return "pending"
        case .allow: return "allow"
        case .deny: return "deny"
        case .answered: return "answer"
        case .withdrawn: return "withdrawn"
        case .gone: return "gone"
        }
    }

    /// Wire JSON: `{"status":"…"}`, plus `"answers"` only for `.answered`.
    public var json: Data {
        var out = #"{"status":"\#(wireName)""#
        if case .answered(let answers) = self {
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            let body = (try? enc.encode(answers)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            out += #","answers":\#(body)"#
        }
        out += "}"
        return Data(out.utf8)
    }
}

public struct PendingDecision: Equatable, Sendable {
    public let id: String
    public let request: DecisionRequest
}
