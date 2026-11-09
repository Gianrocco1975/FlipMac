import Foundation

/// Conversioni tra JSON, YAML, XML e CSV, ed esportazione in TXT, HTML, Markdown e PDF.
/// Non richiede strumenti esterni.
enum StructuredConverter {
    static func convert(input: URL, source: String, target: String, output: URL) throws {
        let node: DataNode
        switch source {
        case "json":
            node = try JSONCodec.parse(try TextIO.read(input))
        case "yaml":
            node = try YAMLCodec.parse(try TextIO.read(input))
        case "xml":
            node = try XMLCodec.parse(try Data(contentsOf: input))
        case "csv":
            node = CSVCodec.parse(try TextIO.read(input))
        default:
            throw FlipError.unsupported("Formato dati non supportato: \(source)")
        }

        let title = input.deletingPathExtension().lastPathComponent

        switch target {
        case "json":
            try TextIO.write(JSONCodec.write(node), to: output)
        case "yaml":
            try TextIO.write(YAMLCodec.write(node), to: output)
        case "xml":
            try TextIO.write(XMLCodec.write(node), to: output)
        case "csv":
            let table = Tabular.table(node)
            try TextIO.write(CSVCodec.write(headers: table.headers, rows: table.rows), to: output)
        case "txt":
            try TextIO.write(Renderers.text(node), to: output)
        case "md":
            try TextIO.write(Renderers.markdown(node, title: title), to: output)
        case "html":
            try TextIO.write(Renderers.html(node, title: title), to: output)
        case "pdf":
            try PDFText.write(text: Renderers.text(node), to: output, monospaced: true)
        default:
            throw FlipError.unsupported("Esportazione non supportata: \(target)")
        }
    }
}
