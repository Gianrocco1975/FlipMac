import Foundation

/// Modello comune per JSON, YAML, XML e CSV. Gli oggetti mantengono l'ordine delle chiavi.
enum DataNode {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([DataNode])
    case object([(key: String, value: DataNode)])

    var isScalar: Bool {
        switch self {
        case .array, .object: return false
        default: return true
        }
    }

    var isObject: Bool {
        if case .object = self { return true }
        return false
    }

    var isArray: Bool {
        if case .array = self { return true }
        return false
    }

    /// Testo del valore, pensato per le celle di una tabella. Array e oggetti diventano JSON compatto.
    var scalarText: String {
        switch self {
        case .null: return ""
        case .bool(let value): return value ? "true" : "false"
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .string(let value): return value
        case .array, .object: return JSONCodec.write(self, pretty: false)
        }
    }

    /// Interpreta un testo semplice (cella CSV o scalare YAML senza virgolette) come valore tipizzato.
    static func infer(_ text: String) -> DataNode {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .null }
        switch trimmed.lowercased() {
        case "true": return .bool(true)
        case "false": return .bool(false)
        case "null", "~": return .null
        default: break
        }
        if trimmed.range(of: "^-?(0|[1-9][0-9]*)$", options: .regularExpression) != nil, let value = Int64(trimmed) {
            return .int(value)
        }
        if trimmed.range(of: "^-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][+-]?[0-9]+)?$", options: .regularExpression) != nil,
           let value = Double(trimmed) {
            return .double(value)
        }
        return .string(text)
    }
}
