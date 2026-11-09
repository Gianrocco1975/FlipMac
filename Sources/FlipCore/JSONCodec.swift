import Foundation

/// Lettura e scrittura JSON con ordine delle chiavi preservato.
enum JSONCodec {
    static func parse(_ text: String) throws -> DataNode {
        var parser = JSONParser(text)
        return try parser.parseDocument()
    }

    static func write(_ node: DataNode, pretty: Bool = true) -> String {
        var output = ""
        emit(node, level: 0, pretty: pretty, into: &output)
        if pretty { output += "\n" }
        return output
    }

    static func quote(_ text: String) -> String {
        var output = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            default:
                if scalar.value < 0x20 {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output += "\""
        return output
    }

    private static func emit(_ node: DataNode, level: Int, pretty: Bool, into output: inout String) {
        switch node {
        case .null:
            output += "null"
        case .bool(let value):
            output += value ? "true" : "false"
        case .int(let value):
            output += String(value)
        case .double(let value):
            output += value.isFinite ? String(value) : "null"
        case .string(let value):
            output += quote(value)
        case .array(let items):
            if items.isEmpty {
                output += "[]"
                return
            }
            output += "["
            for (index, item) in items.enumerated() {
                if index > 0 { output += "," }
                if pretty { output += "\n" + String(repeating: "  ", count: level + 1) }
                emit(item, level: level + 1, pretty: pretty, into: &output)
            }
            if pretty { output += "\n" + String(repeating: "  ", count: level) }
            output += "]"
        case .object(let pairs):
            if pairs.isEmpty {
                output += "{}"
                return
            }
            output += "{"
            for (index, pair) in pairs.enumerated() {
                if index > 0 { output += "," }
                if pretty { output += "\n" + String(repeating: "  ", count: level + 1) }
                output += quote(pair.key)
                output += pretty ? ": " : ":"
                emit(pair.value, level: level + 1, pretty: pretty, into: &output)
            }
            if pretty { output += "\n" + String(repeating: "  ", count: level) }
            output += "}"
        }
    }
}

private struct JSONParser {
    private let bytes: [UInt8]
    private var index = 0

    init(_ text: String) {
        var data = Array(text.utf8)
        if data.count >= 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF {
            data.removeFirst(3)
        }
        bytes = data
    }

    mutating func parseDocument() throws -> DataNode {
        skipWhitespace()
        let value = try parseValue(depth: 0)
        skipWhitespace()
        if index < bytes.count {
            throw failure("contenuto inatteso dopo il valore principale")
        }
        return value
    }

    private func failure(_ message: String) -> FlipError {
        var line = 1
        let limit = min(index, bytes.count)
        var position = 0
        while position < limit {
            if bytes[position] == 0x0A { line += 1 }
            position += 1
        }
        return FlipError.parse("JSON non valido (riga \(line)): \(message)")
    }

    private mutating func skipWhitespace() {
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
                index += 1
            } else {
                break
            }
        }
    }

    private mutating func parseValue(depth: Int) throws -> DataNode {
        if depth > 512 { throw failure("annidamento troppo profondo") }
        guard index < bytes.count else { throw failure("fine del file inattesa") }
        switch bytes[index] {
        case 0x7B:
            return try parseObject(depth: depth)
        case 0x5B:
            return try parseArray(depth: depth)
        case 0x22:
            let text = try parseString()
            return .string(text)
        case 0x74:
            try expect("true")
            return .bool(true)
        case 0x66:
            try expect("false")
            return .bool(false)
        case 0x6E:
            try expect("null")
            return .null
        default:
            return try parseNumber()
        }
    }

    private mutating func expect(_ word: String) throws {
        let expected = Array(word.utf8)
        guard index + expected.count <= bytes.count,
              Array(bytes[index..<(index + expected.count)]) == expected else {
            throw failure("valore non riconosciuto")
        }
        index += expected.count
    }

    private mutating func parseNumber() throws -> DataNode {
        let start = index
        while index < bytes.count, "+-0123456789.eE".utf8.contains(bytes[index]) {
            index += 1
        }
        guard index > start else { throw failure("carattere inatteso") }
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        let isInteger = !text.utf8.contains(where: { $0 == 0x2E || $0 == 0x65 || $0 == 0x45 })
        if isInteger, let value = Int64(text) {
            return .int(value)
        }
        if let value = Double(text) {
            return .double(value)
        }
        throw failure("numero non valido '\(text)'")
    }

    private mutating func parseObject(depth: Int) throws -> DataNode {
        index += 1
        var pairs = [(key: String, value: DataNode)]()
        skipWhitespace()
        if index < bytes.count, bytes[index] == 0x7D {
            index += 1
            return .object(pairs)
        }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == 0x22 else {
                throw failure("era attesa una chiave tra virgolette")
            }
            let key = try parseString()
            skipWhitespace()
            guard index < bytes.count, bytes[index] == 0x3A else {
                throw failure("erano attesi i due punti dopo la chiave")
            }
            index += 1
            skipWhitespace()
            let value = try parseValue(depth: depth + 1)
            pairs.append((key: key, value: value))
            skipWhitespace()
            guard index < bytes.count else { throw failure("oggetto non chiuso") }
            if bytes[index] == 0x2C {
                index += 1
                continue
            }
            if bytes[index] == 0x7D {
                index += 1
                return .object(pairs)
            }
            throw failure("era attesa una virgola oppure '}'")
        }
    }

    private mutating func parseArray(depth: Int) throws -> DataNode {
        index += 1
        var items = [DataNode]()
        skipWhitespace()
        if index < bytes.count, bytes[index] == 0x5D {
            index += 1
            return .array(items)
        }
        while true {
            skipWhitespace()
            let value = try parseValue(depth: depth + 1)
            items.append(value)
            skipWhitespace()
            guard index < bytes.count else { throw failure("array non chiuso") }
            if bytes[index] == 0x2C {
                index += 1
                continue
            }
            if bytes[index] == 0x5D {
                index += 1
                return .array(items)
            }
            throw failure("era attesa una virgola oppure ']'")
        }
    }

    private mutating func parseString() throws -> String {
        index += 1
        var buffer = [UInt8]()
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x22 {
                index += 1
                return String(decoding: buffer, as: UTF8.self)
            }
            if byte == 0x5C {
                index += 1
                guard index < bytes.count else { break }
                let escape = bytes[index]
                index += 1
                switch escape {
                case 0x22: buffer.append(0x22)
                case 0x5C: buffer.append(0x5C)
                case 0x2F: buffer.append(0x2F)
                case 0x62: buffer.append(0x08)
                case 0x66: buffer.append(0x0C)
                case 0x6E: buffer.append(0x0A)
                case 0x72: buffer.append(0x0D)
                case 0x74: buffer.append(0x09)
                case 0x75:
                    var code = try parseHex4()
                    if (0xD800...0xDBFF).contains(code),
                       index + 1 < bytes.count, bytes[index] == 0x5C, bytes[index + 1] == 0x75 {
                        let saved = index
                        index += 2
                        let low = try parseHex4()
                        if (0xDC00...0xDFFF).contains(low) {
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        } else {
                            index = saved
                        }
                    }
                    if let scalar = Unicode.Scalar(code) {
                        buffer.append(contentsOf: Array(String(Character(scalar)).utf8))
                    } else {
                        buffer.append(contentsOf: Array("\u{FFFD}".utf8))
                    }
                default:
                    throw failure("sequenza di escape non valida")
                }
            } else {
                buffer.append(byte)
                index += 1
            }
        }
        throw failure("stringa non terminata")
    }

    private mutating func parseHex4() throws -> UInt32 {
        guard index + 4 <= bytes.count else { throw failure("sequenza \\u incompleta") }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let byte = bytes[index]
            index += 1
            let digit: UInt32
            switch byte {
            case 0x30...0x39: digit = UInt32(byte) - 0x30
            case 0x41...0x46: digit = UInt32(byte) - 0x41 + 10
            case 0x61...0x66: digit = UInt32(byte) - 0x61 + 10
            default: throw failure("cifra esadecimale non valida")
            }
            value = value * 16 + digit
        }
        return value
    }
}
