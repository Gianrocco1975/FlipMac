import Foundation

/// Esportazioni leggibili dei dati strutturati: TXT, Markdown e HTML.
enum Renderers {
    static func text(_ node: DataNode) -> String {
        if let table = Tabular.naturalTable(node) {
            return plainTable(headers: table.headers, rows: table.rows)
        }
        return YAMLCodec.write(node)
    }

    static func markdown(_ node: DataNode, title: String) -> String {
        var output = "# \(title)\n\n"
        if let table = Tabular.naturalTable(node) {
            output += "| " + table.headers.map(markdownCell).joined(separator: " | ") + " |\n"
            output += "|" + table.headers.map { _ in " --- " }.joined(separator: "|") + "|\n"
            for row in table.rows {
                output += "| " + row.map(markdownCell).joined(separator: " | ") + " |\n"
            }
        } else {
            output += "```yaml\n" + YAMLCodec.write(node) + "```\n"
        }
        return output
    }

    static func html(_ node: DataNode, title: String) -> String {
        let body: String
        if let table = Tabular.naturalTable(node) {
            var markup = "<table>\n<thead><tr>"
            for header in table.headers { markup += "<th>\(escapeHTML(header))</th>" }
            markup += "</tr></thead>\n<tbody>\n"
            for row in table.rows {
                markup += "<tr>"
                for cell in row { markup += "<td>\(escapeHTML(cell))</td>" }
                markup += "</tr>\n"
            }
            markup += "</tbody>\n</table>"
            body = markup
        } else {
            body = "<pre>" + escapeHTML(YAMLCodec.write(node)) + "</pre>"
        }

        let style = "body{font-family:-apple-system,Helvetica,Arial,sans-serif;margin:2rem}"
            + "table{border-collapse:collapse}"
            + "th,td{border:1px solid #ccc;padding:4px 10px;text-align:left;vertical-align:top}"
            + "th{background:#f3f3f3}pre{font-size:13px}"

        return """
        <!DOCTYPE html>
        <html lang="it">
        <head>
        <meta charset="utf-8">
        <title>\(escapeHTML(title))</title>
        <style>\(style)</style>
        </head>
        <body>
        <h1>\(escapeHTML(title))</h1>
        \(body)
        </body>
        </html>

        """
    }

    // MARK: - Utilità

    private static func plainTable(headers: [String], rows: [[String]]) -> String {
        var widths = headers.map { oneLine($0).count }
        for row in rows {
            for (position, cell) in row.enumerated() where position < widths.count {
                widths[position] = max(widths[position], oneLine(cell).count)
            }
        }
        func render(_ cells: [String]) -> String {
            var parts = [String]()
            for (position, cell) in cells.enumerated() where position < widths.count {
                parts.append(oneLine(cell).padding(toLength: widths[position], withPad: " ", startingAt: 0))
            }
            return parts.joined(separator: "  ")
        }
        var lines = [render(headers)]
        lines.append(widths.map { String(repeating: "-", count: $0) }.joined(separator: "  "))
        for row in rows { lines.append(render(row)) }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func oneLine(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private static func markdownCell(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: "<br>")
            .replacingOccurrences(of: "\n", with: "<br>")
            .replacingOccurrences(of: "\r", with: "<br>")
    }

    private static func escapeHTML(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
