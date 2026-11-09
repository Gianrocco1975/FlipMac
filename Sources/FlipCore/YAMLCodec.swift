import Foundation
import Yams

/// YAML: lettura con Yams (ordine delle chiavi preservato), scrittura con un emettitore proprio.
enum YAMLCodec {
    static func parse(_ text: String) throws -> DataNode {
        do {
            guard let root = try Yams.compose(yaml: text) else { return .null }
            return convert(root)
        } catch {
            throw FlipError.parse("YAML non valido: \(error)")
        }
    }

    private static func convert(_ node: Yams.Node) -> DataNode {
        switch node {
        case .scalar(let scalar):
            switch scalar.style {
            case .plain, .any:
                return DataNode.infer(scalar.string)
            default:
                return .string(scalar.string)
            }
        case .mapping(let mapping):
            var pairs = [(key: String, value: DataNode)]()
            for pair in mapping {
                let key: String
                if case .scalar(let keyScalar) = pair.key {
                    key = keyScalar.string
                } else {
                    key = "?"
                }
                pairs.append((key: key, value: convert(pair.value)))
            }
            return .object(pairs)
        case .sequence(let sequence):
            return .array(sequence.map { convert($0) })
        default:
            return .null
        }
    }

    // MARK: - Scrittura

    static func write(_ node: DataNode) -> String {
        return lines(node, indent: 0).joined(separator: "\n") + "\n"
    }

    private static func lines(_ node: DataNode, indent: Int) -> [String] {
        let pad = String(repeating: " ", count: indent)
        switch node {
        case .object(let pairs) where !pairs.isEmpty:
            var output = [String]()
            for pair in pairs {
                let key = scalar(.string(pair.key))
                switch pair.value {
                case .object(let inner) where !inner.isEmpty:
                    output.append(pad + key + ":")
                    output += lines(pair.value, indent: indent + 2)
                case .array(let inner) where !inner.isEmpty:
                    output.append(pad + key + ":")
                    output += lines(pair.value, indent: indent + 2)
                default:
                    output.append(pad + key + ": " + scalar(pair.value))
                }
            }
            return output
        case .array(let items) where !items.isEmpty:
            var output = [String]()
            for item in items {
                switch item {
                case .object(let inner) where !inner.isEmpty:
                    let nested = lines(item, indent: indent + 2)
                    output.append(pad + "- " + String(nested[0].dropFirst(indent + 2)))
                    output += nested.dropFirst()
                case .array(let inner) where !inner.isEmpty:
                    let nested = lines(item, indent: indent + 2)
                    output.append(pad + "- " + String(nested[0].dropFirst(indent + 2)))
                    output += nested.dropFirst()
                default:
                    output.append(pad + "- " + scalar(item))
                }
            }
            return output
        default:
            return [pad + scalar(node)]
        }
    }

    private static func scalar(_ node: DataNode) -> String {
        switch node {
        case .null:
            return "null"
        case .bool(let value):
            return value ? "true" : "false"
        case .int(let value):
            return String(value)
        case .double(let value):
            if value.isNaN { return ".nan" }
            if value.isInfinite { return value < 0 ? "-.inf" : ".inf" }
            return String(value)
        case .string(let value):
            return needsQuotes(value) ? JSONCodec.quote(value) : value
        case .array:
            return "[]"
        case .object:
            return "{}"
        }
    }

    private static func needsQuotes(_ text: String) -> Bool {
        if text.isEmpty { return true }
        if text != text.trimmingCharacters(in: .whitespaces) { return true }
        let lower = text.lowercased()
        if ["null", "~", "true", "false", "yes", "no", "on", "off", "y", "n"].contains(lower) { return true }
        // Numeri, date e simili: iniziano con una cifra (anche dopo un segno o un punto).
        if text.range(of: "^[-+.]?[0-9]", options: .regularExpression) != nil { return true }
        let specialStart = "-?:,[]{}#&*!|>'\"%@`".unicodeScalars
        if let first = text.unicodeScalars.first, specialStart.contains(first) { return true }
        if text.range(of: ": ") != nil || text.range(of: " #") != nil || text.hasSuffix(":") { return true }
        for scalar in text.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F || scalar.value == 0x85
                || scalar.value == 0x2028 || scalar.value == 0x2029 {
                return true
            }
        }
        return false
    }
}
