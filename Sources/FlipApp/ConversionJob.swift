import Foundation
import FlipCore

/// Converte una serie di file, uno dopo l'altro, su un thread di lavoro. Si può annullare in qualsiasi momento.
final class ConversionJob: @unchecked Sendable {
    struct Summary: Sendable {
        var outputs: [URL] = []
        var failures: [String] = []
        var notes: [String] = []
        var cancelled = false
    }

    let files: [URL]
    let target: String

    private let lock = NSLock()
    private var converter: Converter?
    private var cancelled = false

    init(files: [URL], target: String) {
        self.files = files
        self.target = target
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let current = converter
        lock.unlock()
        current?.cancel()
    }

    /// Bloccante: da chiamare fuori dal thread principale.
    /// `progress` riceve l'avanzamento complessivo (0...1) e l'indice del file in corso.
    func run(progress: @escaping @Sendable (Double, Int) -> Void) -> Summary {
        var summary = Summary()
        let total = Double(max(files.count, 1))

        for (index, file) in files.enumerated() {
            lock.lock()
            if cancelled {
                lock.unlock()
                summary.cancelled = true
                break
            }
            let converter = Converter()
            self.converter = converter
            lock.unlock()

            progress(Double(index) / total, index)
            do {
                let result = try converter.convert(input: file, to: target) { fraction in
                    progress((Double(index) + fraction) / total, index)
                }
                summary.outputs.append(contentsOf: result.outputs)
                for note in result.notes {
                    summary.notes.append("\(file.lastPathComponent): \(note)")
                }
            } catch FlipError.cancelled {
                summary.cancelled = true
                break
            } catch {
                summary.failures.append("\(file.lastPathComponent): \(error.localizedDescription)")
            }
        }

        lock.lock()
        converter = nil
        lock.unlock()
        return summary
    }
}

/// Registro diagnostico locale: ~/Library/Logs/FlipMac/flip.log
enum FlipLog {
    static let url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/FlipMac/flip.log")

    static func write(_ message: String) {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = Data("\(stamp)  \(message)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }
}
