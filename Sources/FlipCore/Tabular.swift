import Foundation

/// Trasforma il modello comune in una tabella (per CSV, Markdown, HTML, TXT e PDF).
enum Tabular {
    typealias Table = (headers: [String], rows: [[String]])

    /// Scende attraverso gli oggetti con un solo contenuto (tipico di XML: root → elemento ripetuto → righe).
    /// Gli attributi XML ("@...") e il testo ("#text") non contano: una radice con xmlns resta attraversabile.
    static func unwrap(_ node: DataNode) -> DataNode {
        var current = node
        while case .object(let pairs) = current {
            let content = pairs.filter { !$0.key.hasPrefix("@") && $0.key != "#text" }
            guard content.count == 1, !content[0].value.isScalar else { break }
            current = content[0].value
        }
        return current
    }

    /// Tabella solo se i dati sono davvero tabellari (array non vuoto di oggetti).
    static func naturalTable(_ node: DataNode) -> Table? {
        let target = unwrap(node)
        if case .array(let items) = target, !items.isEmpty, items.allSatisfy({ $0.isObject }) {
            return table(target)
        }
        return nil
    }

    /// Tabella per qualsiasi struttura: produce sempre qualcosa di sensato.
    static func table(_ node: DataNode) -> Table {
        let target = unwrap(node)
        switch target {
        case .array(let items):
            if !items.isEmpty && items.allSatisfy({ $0.isObject }) {
                return objectsTable(items)
            }
            if !items.isEmpty && items.allSatisfy({ $0.isArray }) {
                return arraysTable(items)
            }
            return (headers: ["value"], rows: items.map { [$0.scalarText] })
        case .object:
            var cells = [(String, String)]()
            flatten(target, prefix: "", into: &cells)
            return (headers: cells.map { $0.0 }, rows: [cells.map { $0.1 }])
        default:
            return (headers: ["value"], rows: [[target.scalarText]])
        }
    }

    private static func objectsTable(_ items: [DataNode]) -> Table {
        var headers = [String]()
        var known = Set<String>()
        var flattened = [[(String, String)]]()
        for item in items {
            var cells = [(String, String)]()
            flatten(item, prefix: "", into: &cells)
            for cell in cells where !known.contains(cell.0) {
                known.insert(cell.0)
                headers.append(cell.0)
            }
            flattened.append(cells)
        }
        let rows = flattened.map { cells -> [String] in
            var lookup = [String: String]()
            for cell in cells where lookup[cell.0] == nil {
                lookup[cell.0] = cell.1
            }
            return headers.map { lookup[$0] ?? "" }
        }
        return (headers: headers, rows: rows)
    }

    private static func arraysTable(_ items: [DataNode]) -> Table {
        var rows = [[String]]()
        var widest = 1
        for item in items {
            if case .array(let cells) = item {
                rows.append(cells.map { $0.scalarText })
                widest = max(widest, cells.count)
            }
        }
        let headers = (1...widest).map { "col\($0)" }
        let padded = rows.map { row in row + Array(repeating: "", count: widest - row.count) }
        return (headers: headers, rows: padded)
    }

    /// Appiattisce gli oggetti annidati con chiavi puntate ("indirizzo.città").
    private static func flatten(_ node: DataNode, prefix: String, into cells: inout [(String, String)]) {
        if case .object(let pairs) = node {
            for pair in pairs {
                let name = prefix.isEmpty ? pair.key : prefix + "." + pair.key
                flatten(pair.value, prefix: name, into: &cells)
            }
        } else {
            cells.append((prefix.isEmpty ? "value" : prefix, node.scalarText))
        }
    }
}
