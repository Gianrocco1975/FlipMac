import Foundation

public struct ConversionResult {
    /// File creati: di solito uno solo; più di uno quando un PDF di più pagine diventa immagini.
    public let outputs: [URL]
    /// Avvisi per l'utente (ad esempio un ripiego usato al posto dello strumento ideale).
    public let notes: [String]

    /// Il primo (spesso l'unico) file creato.
    public var output: URL { outputs[0] }
}

/// Punto di ingresso del motore: converte un file e crea la copia accanto all'originale.
/// Non sovrascrive mai nulla: se il nome esiste già aggiunge " (1)", " (2)"...
public final class Converter {
    private let runner: ProcessRunner

    public init() {
        runner = ProcessRunner()
    }

    /// Converter che condivide l'annullamento con un altro (conversioni in due tappe, ad esempio .p7m → Word → PDF).
    init(runner: ProcessRunner) {
        self.runner = runner
    }

    /// Annulla la conversione in corso (e quelle successive di questa istanza).
    public func cancel() {
        runner.cancel()
    }

    public func convert(input: URL, to rawTarget: String, progress: ((Double) -> Void)? = nil) throws -> ConversionResult {
        let source = FlipFormat.normalize(input.pathExtension)
        let target = FlipFormat.normalize(rawTarget)

        guard let category = FlipFormat.category(of: source) else {
            throw FlipError.unsupported("Formato di origine non supportato: .\(input.pathExtension)")
        }
        // Per i .p7m i formati dipendono dal documento firmato: si guarda il nome intero ("fattura.xml.p7m").
        let allowed = category == .signed ? FlipFormat.targets(for: input) : FlipFormat.targets(for: source)
        guard allowed.contains(target) else {
            throw FlipError.unsupported("Da .\(source) non si può convertire in .\(target). Formati disponibili: \(allowed.joined(separator: ", "))")
        }
        guard FileManager.default.isReadableFile(atPath: input.path) else {
            throw FlipError.failed("File non leggibile: \(input.path)")
        }

        let directory = input.deletingLastPathComponent()
        // "atto.pdf.p7m" → "atto.pdf", non "atto.pdf.pdf".
        let base = category == .signed ? SignedFile.baseName(of: input) : input.deletingPathExtension().lastPathComponent
        let token = UUID().uuidString.prefix(8)
        let temp = directory.appendingPathComponent(".\(base).\(token).flip-partial.\(target)")

        var notes = [String]()
        var produced = [temp]
        do {
            switch category {
            case .video, .audio:
                try MediaConverter(runner: runner).convert(input: input, target: target, output: temp, progress: progress, notes: &notes)
            case .image:
                try ImageConverter(runner: runner).convert(input: input, target: target, output: temp, notes: &notes)
            case .structured:
                try StructuredConverter.convert(input: input, source: source, target: target, output: temp)
            case .document:
                try DocumentConverter(runner: runner).convert(input: input, source: source, target: target, output: temp, notes: &notes)
            case .pdf:
                produced = try PDFConverter(runner: runner).convert(input: input, target: target, output: temp, progress: progress, notes: &notes)
            case .signed:
                try SignedConverter(runner: runner).convert(input: input, target: target, output: temp, progress: progress, notes: &notes)
            }
            progress?(1.0)

            var finals = [URL]()
            for (index, file) in produced.enumerated() {
                let name = produced.count == 1 ? base : "\(base) - pagina \(index + 1)"
                let final = Converter.uniqueURL(directory: directory, base: name, ext: target)
                try FileManager.default.moveItem(at: file, to: final)
                finals.append(final)
            }
            return ConversionResult(outputs: finals, notes: notes)
        } catch {
            for file in Set(produced + [temp]) {
                try? FileManager.default.removeItem(at: file)
            }
            throw error
        }
    }

    static func uniqueURL(directory: URL, base: String, ext: String) -> URL {
        var candidate = directory.appendingPathComponent("\(base).\(ext)")
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) (\(counter)).\(ext)")
            counter += 1
        }
        return candidate
    }
}
