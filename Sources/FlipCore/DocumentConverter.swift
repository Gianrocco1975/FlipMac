import Foundation

/// Conversioni di documenti: `textutil` (incluso in macOS) per i formati comuni, Pandoc per il resto,
/// LibreOffice per i PDF fedeli.
struct DocumentConverter {
    let runner: ProcessRunner

    private static let textutilFormats: Set<String> = ["txt", "rtf", "html", "docx", "odt"]
    private static let sofficeInputs: Set<String> = ["txt", "rtf", "html", "docx", "odt"]

    private static let readers: [String: String] = [
        "txt": "markdown", "md": "markdown", "html": "html", "docx": "docx", "epub": "epub",
        "odt": "odt", "rtf": "rtf", "fb2": "fb2", "rst": "rst"
    ]
    private static let writers: [String: String] = [
        "txt": "plain", "md": "gfm", "html": "html5", "docx": "docx", "epub": "epub",
        "odt": "odt", "rtf": "rtf", "fb2": "fb2", "rst": "rst"
    ]

    func convert(input: URL, source: String, target: String, output: URL, notes: inout [String]) throws {
        if target == "pdf" {
            try toPDF(input: input, source: source, output: output, notes: &notes)
            return
        }

        let pandoc = ToolLocator.find("pandoc")
        let textutilCanDoIt = Self.textutilFormats.contains(source) && Self.textutilFormats.contains(target)
        if textutilCanDoIt, let textutil = ToolLocator.find("textutil"), pandoc == nil || source == "txt" {
            try runner.run(textutil, ["-convert", target, "-output", output.path, input.path])
            return
        }

        guard let pandoc = pandoc else {
            throw FlipError.missingTool(name: "pandoc", hint: "Installalo con: brew install pandoc")
        }
        try runPandoc(pandoc, input: input, source: source, target: target, output: output)
    }

    private func runPandoc(_ pandoc: URL, input: URL, source: String, target: String, output: URL) throws {
        guard let reader = Self.readers[source], let writer = Self.writers[target] else {
            throw FlipError.unsupported("Conversione non supportata: \(source) → \(target)")
        }
        let base = input.deletingPathExtension().lastPathComponent
        var arguments = ["-f", reader, "-t", writer, "-o", output.path]
        switch writer {
        case "html5":
            arguments += ["-s", "--metadata", "pagetitle=\(base)"]
        case "rtf":
            arguments += ["-s"]
        case "epub", "fb2":
            arguments += ["--metadata", "title=\(base)"]
        case "gfm", "plain", "rst":
            arguments += ["--wrap=none"]
        default:
            break
        }
        arguments.append(input.path)
        try runner.run(pandoc, arguments)
    }

    /// PDF: per DOCX/ODT/RTF/HTML/TXT prima LibreOffice (il più fedele), poi pandoc con un motore PDF,
    /// infine un PDF di solo testo.
    private func toPDF(input: URL, source: String, output: URL, notes: inout [String]) throws {
        let base = input.deletingPathExtension().lastPathComponent

        if Self.sofficeInputs.contains(source),
           try LibreOffice(runner: runner).convert(input, to: "pdf", output: output) {
            return
        }

        if let pandoc = ToolLocator.find("pandoc"), let engine = ToolLocator.firstPDFEngine(), let reader = Self.readers[source] {
            do {
                try runner.run(pandoc, [
                    "-f", reader, "-s", "-o", output.path,
                    "--pdf-engine=\(engine.path)",
                    "--metadata", "title=\(base)",
                    input.path
                ])
                return
            } catch FlipError.cancelled {
                throw FlipError.cancelled
            } catch {
                try? FileManager.default.removeItem(at: output)
            }
        }

        let text = try plainText(of: input, source: source)
        try PDFText.write(text: text, to: output, monospaced: false)
        notes.append("PDF creato come testo semplice (nessun motore PDF trovato). Per un PDF fedele all'originale installa LibreOffice (brew install --cask libreoffice) oppure weasyprint (brew install weasyprint).")
    }

    private func plainText(of input: URL, source: String) throws -> String {
        if source == "txt" || source == "md" {
            return try TextIO.read(input)
        }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("flip-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: temp) }

        if let pandoc = ToolLocator.find("pandoc"), let reader = Self.readers[source] {
            try runner.run(pandoc, ["-f", reader, "-t", "plain", "--wrap=auto", "-o", temp.path, input.path])
        } else if Self.textutilFormats.contains(source), let textutil = ToolLocator.find("textutil") {
            try runner.run(textutil, ["-convert", "txt", "-output", temp.path, input.path])
        } else {
            throw FlipError.missingTool(name: "pandoc", hint: "Installalo con: brew install pandoc")
        }
        return try TextIO.read(temp)
    }
}
