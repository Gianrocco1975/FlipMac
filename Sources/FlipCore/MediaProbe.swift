import Foundation

/// Guarda dentro i file audio/video con ffprobe.
public enum MediaProbe {
    /// Numero di tracce audio del file; nil se ffprobe non c'è o non riesce a leggerlo.
    public static func audioStreamCount(_ url: URL) -> Int? {
        guard let ffprobe = ToolLocator.find("ffprobe") else { return nil }
        let process = Process()
        process.executableURL = ffprobe
        process.arguments = [
            "-v", "error",
            "-select_streams", "a",
            "-show_entries", "stream=index",
            "-of", "csv=p=0",
            url.path
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count
    }
}

extension FlipFormat {
    /// Come `targets(for:)` con l'estensione, ma guarda anche dentro il file:
    /// a un video senza traccia audio (ad esempio una registrazione dello schermo) non propone i formati audio.
    /// Per un .p7m propone anche il documento originale, se dal nome si capisce che non è un PDF ("fattura.xml.p7m").
    public static func targets(for url: URL) -> [String] {
        let all = targets(for: url.pathExtension)
        switch category(of: url.pathExtension) {
        case .video?:
            return MediaProbe.audioStreamCount(url) == 0 ? all.filter { !audio.contains($0) } : all
        case .signed?:
            if let inner = SignedFile.innerExtension(of: url), !all.contains(inner) {
                return all + [inner]
            }
            return all
        default:
            return all
        }
    }
}
