import Foundation

/// CSV (RFC 4180): separatore riconosciuto in automatico tra virgola, punto e virgola e tabulazione.
enum CSVCodec {
    /// La prima riga è l'intestazione; il risultato è un array di oggetti.
    static func parse(_ text: String) -> DataNode {
        let rows = parseRows(text)
        guard let headerRow = rows.first else { return .array([]) }

        var headers = [String]()
        var seen = [String: Int]()
        for (position, rawHeader) in headerRow.enumerated() {
            var name = rawHeader.trimmingCharacters(in: .whitespaces)
            if name.isEmpty { name = "col\(position + 1)" }
            if let count = seen[name] {
                seen[name] = count + 1
                name += "_\(count + 1)"
            } else {
                seen[name] = 1
            }
            headers.append(name)
        }

        var items = [DataNode]()
        for row in rows.dropFirst() {
            var pairs = [(key: String, value: DataNode)]()
            for (position, header) in headers.enumerated() {
                let cell = position < row.count ? row[position] : ""
                pairs.append((key: header, value: DataNode.infer(cell)))
            }
            if row.count > headers.count {
                for position in headers.count..<row.count {
                    pairs.append((key: "col\(position + 1)", value: DataNode.infer(row[position])))
                }
            }
            items.append(.object(pairs))
        }
        return .array(items)
    }

    static func write(headers: [String], rows: [[String]], delimiter: Unicode.Scalar = ",") -> String {
        let separator = String(Character(delimiter))
        var lines = [String]()
        lines.append(headers.map { escape($0, delimiter: delimiter) }.joined(separator: separator))
        for row in rows {
            lines.append(row.map { escape($0, delimiter: delimiter) }.joined(separator: separator))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func escape(_ cell: String, delimiter: Unicode.Scalar) -> String {
        var needsQuotes = cell.hasPrefix(" ") || cell.hasSuffix(" ")
        if !needsQuotes {
            for scalar in cell.unicodeScalars {
                if scalar == delimiter || scalar == "\"" || scalar == "\n" || scalar == "\r" {
                    needsQuotes = true
                    break
                }
            }
        }
        if needsQuotes {
            return "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return cell
    }

    // MARK: - Parser

    private static func detectDelimiter(_ scalars: [Unicode.Scalar]) -> Unicode.Scalar {
        var commas = 0
        var semicolons = 0
        var tabs = 0
        var inQuotes = false
        for scalar in scalars {
            if scalar == "\"" { inQuotes.toggle(); continue }
            if inQuotes { continue }
            if scalar == "\n" || scalar == "\r" { break }
            if scalar == "," { commas += 1 }
            if scalar == ";" { semicolons += 1 }
            if scalar == "\t" { tabs += 1 }
        }
        if semicolons > commas && semicolons >= tabs { return ";" }
        if tabs > commas && tabs > semicolons { return "\t" }
        return ","
    }

    private static func parseRows(_ text: String) -> [[String]] {
        var scalars = Array(text.unicodeScalars)
        if let first = scalars.first, first == "\u{FEFF}" {
            scalars.removeFirst()
        }
        let delimiter = detectDelimiter(scalars)

        var rows = [[String]]()
        var row = [String]()
        var field = String.UnicodeScalarView()
        var inQuotes = false
        var position = 0

        while position < scalars.count {
            let scalar = scalars[position]
            if inQuotes {
                if scalar == "\"" {
                    if position + 1 < scalars.count, scalars[position + 1] == "\"" {
                        field.append("\"")
                        position += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(scalar)
                }
            } else if scalar == "\"" && field.isEmpty {
                inQuotes = true
            } else if scalar == delimiter {
                row.append(String(field))
                field = String.UnicodeScalarView()
            } else if scalar == "\n" || scalar == "\r" {
                if scalar == "\r", position + 1 < scalars.count, scalars[position + 1] == "\n" {
                    position += 1
                }
                row.append(String(field))
                field = String.UnicodeScalarView()
                rows.append(row)
                row = []
            } else {
                field.append(scalar)
            }
            position += 1
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(String(field))
            rows.append(row)
        }
        return rows.filter { !($0.count == 1 && $0[0].isEmpty) }
    }
}
