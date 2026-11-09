import Foundation

/// Conversioni con LibreOffice senza interfaccia (soffice --headless).
struct LibreOffice {
    let runner: ProcessRunner

    /// Profilo riservato a FlipMac: separato da quello personale (così funziona anche se LibreOffice è aperto)
    /// e riusato tra una conversione e l'altra (così non riparte ogni volta da zero).
    static let profile: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("FlipMac/libreoffice-profile")
    }()

    static var isAvailable: Bool {
        return ToolLocator.find("soffice") != nil
    }

    /// Converte `input` nel formato `format` (pdf, odt, rtf, docx...) e lo scrive in `output`.
    /// Restituisce false se LibreOffice non c'è o non ha creato il file.
    func convert(_ input: URL, to format: String, output: URL) throws -> Bool {
        guard let soffice = ToolLocator.find("soffice") else { return false }
        if try attempt(soffice, input: input, format: format, output: output, profile: Self.profile) {
            return true
        }
        // Profilo condiviso occupato o rovinato: si riprova con un profilo nuovo e temporaneo.
        return try attempt(soffice, input: input, format: format, output: output, profile: nil)
    }

    private func attempt(_ soffice: URL, input: URL, format: String, output: URL, profile: URL?) throws -> Bool {
        let fileManager = FileManager.default
        let workDirectory = fileManager.temporaryDirectory.appendingPathComponent("flip-\(UUID().uuidString)")
        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workDirectory) }

        let profileDirectory = profile ?? workDirectory.appendingPathComponent("profile")
        try? fileManager.createDirectory(at: profileDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
        let profileURL = URL(fileURLWithPath: profileDirectory.path).absoluteString

        do {
            try runner.run(soffice, [
                "-env:UserInstallation=\(profileURL)",
                "--headless", "--norestore",
                "--convert-to", format, "--outdir", workDirectory.path, input.path
            ])
        } catch FlipError.cancelled {
            throw FlipError.cancelled
        } catch {
            return false
        }

        let base = input.deletingPathExtension().lastPathComponent
        let produced = workDirectory.appendingPathComponent("\(base).\(format)")
        guard fileManager.fileExists(atPath: produced.path) else { return false }
        if fileManager.fileExists(atPath: output.path) {
            try fileManager.removeItem(at: output)
        }
        try fileManager.moveItem(at: produced, to: output)
        return true
    }
}
