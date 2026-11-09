import Foundation
import Security

/// .p7m → documento originale (o PDF), con il framework di sicurezza di macOS (CMSDecoder).
/// Gestisce .p7m in DER o in Base64 e firme annidate (.p7m.p7m). Non verifica la validità legale della firma.
struct SignedConverter {
    let runner: ProcessRunner

    func convert(input: URL, target: String, output: URL, progress: ((Double) -> Void)?, notes: inout [String]) throws {
        let data = try Data(contentsOf: input)
        let (content, signers) = try Self.extract(from: data)
        progress?(0.5)

        if !signers.isEmpty {
            notes.append("Firmato da: \(signers.joined(separator: "; ")). Il file estratto non contiene la firma digitale: per il valore legale conserva il .p7m (FlipMac non verifica la validità della firma).")
        }

        let inner = SignedFile.sniff(content) ?? SignedFile.innerExtension(of: input)

        // Il documento è già nel formato richiesto: si scrive così com'è.
        if target == inner || (target == "pdf" && SignedFile.sniff(content) == "pdf") {
            try content.write(to: output)
            return
        }

        guard target == "pdf" else {
            throw FlipError.unsupported("Il documento firmato non è un file .\(target).")
        }

        // Documento non PDF (Word, XML, immagine…): lo si estrae in una cartella temporanea e lo si converte in PDF.
        guard let innerFormat = inner, FlipFormat.targets(for: innerFormat).contains("pdf") else {
            throw FlipError.unsupported("Il documento firmato è un file .\(inner ?? "sconosciuto"): FlipMac non sa trasformarlo in PDF. Puoi estrarlo così com'è.")
        }
        let fileManager = FileManager.default
        let workDirectory = fileManager.temporaryDirectory.appendingPathComponent("flip-\(UUID().uuidString)")
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workDirectory) }

        let extracted = workDirectory.appendingPathComponent("\(SignedFile.baseName(of: input)).\(innerFormat)")
        try content.write(to: extracted)
        let result = try Converter(runner: runner).convert(input: extracted, to: "pdf") { fraction in
            progress?(0.5 + fraction / 2)
        }
        notes.append(contentsOf: result.notes)
        try fileManager.moveItem(at: result.output, to: output)
    }

    /// Contenuto della busta (anche annidata) e nomi dei firmatari.
    static func extract(from data: Data) throws -> (content: Data, signers: [String]) {
        var current = data
        var signers = [String]()
        var levels = 0

        // Si apre una busta alla volta: il contenuto può essere a sua volta un .p7m (firme annidate).
        while levels < 5 {
            let candidate = SignedFile.der(from: current)
            guard SignedFile.isDER(candidate), let decoded = decode(candidate) else { break }
            for name in decoded.signers where !signers.contains(name) {
                signers.append(name)
            }
            current = decoded.content
            levels += 1
        }

        guard levels > 0 else {
            throw FlipError.failed("Il file .p7m non contiene una busta di firma leggibile (file danneggiato o firma \"separata\" .p7s).")
        }
        guard !current.isEmpty else {
            throw FlipError.failed("La busta di firma è vuota: il documento non è incluso (firma \"separata\").")
        }
        return (current, signers)
    }

    /// Una busta CMS: contenuto e nomi dei firmatari (nil se i dati non sono una busta CMS).
    private static func decode(_ der: Data) -> (content: Data, signers: [String])? {
        var decoderOut: CMSDecoder?
        guard CMSDecoderCreate(&decoderOut) == errSecSuccess, let decoder = decoderOut else { return nil }

        let updated: OSStatus = der.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return errSecParam }
            return CMSDecoderUpdateMessage(decoder, base, buffer.count)
        }
        guard updated == errSecSuccess, CMSDecoderFinalizeMessage(decoder) == errSecSuccess else { return nil }

        var contentOut: CFData?
        guard CMSDecoderCopyContent(decoder, &contentOut) == errSecSuccess, let cfContent = contentOut else {
            return nil
        }
        let content = cfContent as Data

        var names = [String]()
        var count = 0
        if CMSDecoderGetNumSigners(decoder, &count) == errSecSuccess {
            for index in 0..<count {
                var certificate: SecCertificate?
                if CMSDecoderCopySignerCert(decoder, index, &certificate) == errSecSuccess,
                   let certificate = certificate,
                   let summary = SecCertificateCopySubjectSummary(certificate) {
                    names.append(summary as String)
                }
            }
        }
        return (content: content, signers: names)
    }
}
