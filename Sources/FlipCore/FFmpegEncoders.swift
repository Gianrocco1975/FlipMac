import Foundation

/// Elenco degli encoder dell'ffmpeg installato, letto una sola volta.
/// Serve perché il pacchetto `ffmpeg` di Homebrew (da gennaio 2026) non include più alcuni encoder,
/// ad esempio libvorbis (OGG) e libwebp (WebP): in quei casi si usa un ripiego.
public enum FFmpegEncoders {
    private static let lock = NSLock()
    private static var cache: [String: Set<String>] = [:]

    /// Insieme vuoto se l'elenco non è leggibile: in quel caso si assume che tutto sia disponibile.
    public static func available(_ ffmpeg: URL) -> Set<String> {
        lock.lock()
        if let cached = cache[ffmpeg.path] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-hide_banner", "-encoders"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        var names = Set<String>()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                // Righe del tipo: " A....D libvorbis            libvorbis (codec vorbis)"
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                if parts.count >= 2, parts[0].count == 6, parts[1] != "=" {
                    names.insert(String(parts[1]))
                }
            }
        } catch {
            names = []
        }

        lock.lock()
        cache[ffmpeg.path] = names
        lock.unlock()
        return names
    }

    /// Vero se l'encoder c'è, oppure se l'elenco non è stato letto.
    public static func has(_ name: String, in encoders: Set<String>) -> Bool {
        return encoders.isEmpty || encoders.contains(name)
    }
}
