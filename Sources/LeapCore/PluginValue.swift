import Foundation

/// 协议内直接传递结构化值，列表不再嵌套编码为 JSON 字符串。
public enum PluginValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([PluginValue])
    case object([String: PluginValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([PluginValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: PluginValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        }
    }

    public var string: String? { if case let .string(value) = self { value } else { nil } }
    public subscript(key: String) -> PluginValue? {
        if case let .object(value) = self { value[key] } else { nil }
    }
}
