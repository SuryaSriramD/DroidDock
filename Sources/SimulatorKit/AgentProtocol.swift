import Foundation

public enum AgentValue: Codable, Sendable, Equatable {
    case string(String), number(Double), bool(Bool), object([String: AgentValue]), array([AgentValue]), null
    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let item = try? value.decode(Bool.self) { self = .bool(item) }
        else if let item = try? value.decode(String.self) { self = .string(item) }
        else if let item = try? value.decode(Double.self) { self = .number(item) }
        else if let item = try? value.decode([String: AgentValue].self) { self = .object(item) }
        else { self = .array(try value.decode([AgentValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let item): try value.encode(item)
        case .number(let item): try value.encode(item)
        case .bool(let item): try value.encode(item)
        case .object(let item): try value.encode(item)
        case .array(let item): try value.encode(item)
        case .null: try value.encodeNil()
        }
    }
    public var string: String? { if case .string(let value) = self { return value }; return nil }
}
public struct AgentEnvelope: Codable, Sendable {
    public let version: Int
    public let connection: UUID
    public let request: UUID
    public let tool: String
    public let args: [String: AgentValue]
}
public enum AgentRuntime {
    public static func resources(in bundle: URL) -> URL { bundle.appendingPathComponent("Contents/Resources/agent", isDirectory: true) }
    public static func node(in bundle: URL) -> URL { resources(in: bundle).appendingPathComponent("node") }
    public static func requireNode(in bundle: URL) throws -> URL {
        let node = node(in: bundle)
        guard FileManager.default.isExecutableFile(atPath: node.path) else {
            throw RuntimeError.invalidArgument("The bundled agent runtime is missing. Install a DroidDock build with Agent Setup support.")
        }
        return node
    }
}
