import Foundation

/// A value in the sync protocol (JSON). Numbers are always `Double`: the server reads whole numbers as integers where it needs them.
enum SyncValue: Codable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported value") }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }

    var string: String? { if case .string(let value) = self { return value } else { return nil } }
    var number: Double? { if case .number(let value) = self { return value } else { return nil } }
    var bool: Bool? { if case .bool(let value) = self { return value } else { return nil } }
    var int: Int? { number.map { Int($0.rounded()) } }

    /// The same value for the sync's purposes: "" and null are the same, numbers compare numerically.
    func matches(_ other: SyncValue) -> Bool {
        switch (self, other) {
        case (.null, .null): return true
        case (.null, .string(let s)), (.string(let s), .null): return s.isEmpty
        case (.number(let a), .number(let b)): return abs(a - b) < 1e-9
        default: return self == other
        }
    }
}

typealias SyncFields = [String: SyncValue]

extension Dictionary where Key == String, Value == SyncValue {
    /// True when both have the same fields with matching values.
    func matches(_ other: SyncFields) -> Bool {
        let keys = Set(self.keys).union(other.keys)
        return keys.allSatisfy { (self[$0] ?? .null).matches(other[$0] ?? .null) }
    }
}
