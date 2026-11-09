import Foundation

/// Esegue un processo esterno, raccoglie l'errore, inoltra l'output riga per riga e permette di annullare.
/// Dopo `cancel()` l'istanza resta annullata: serve una nuova istanza per una nuova conversione.
///
/// Le due pipe vengono lette con letture bloccanti su thread separati: ogni thread tiene viva la propria pipe
/// finché non arriva alla fine, così su macOS non si legge mai da un descrittore già chiuso.
public final class ProcessRunner {
    private final class ErrorBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            if data.count > 32_768 {
                data = Data(data.suffix(16_384))
            }
            lock.unlock()
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }
    }

    private let lock = NSLock()
    private var current: Process?
    private var cancelledFlag = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledFlag
    }

    public func cancel() {
        lock.lock()
        cancelledFlag = true
        let process = current
        lock.unlock()
        if let process = process, process.isRunning {
            process.terminate()
        }
    }

    /// Restituisce lo standard error del processo. Lancia `FlipError.failed` se il codice di uscita non è 0.
    /// `onStdoutLine` e `onStderrLine` ricevono le righe man mano che arrivano (servono per l'avanzamento).
    @discardableResult
    func run(_ executable: URL, _ arguments: [String],
             onStdoutLine: ((String) -> Void)? = nil,
             onStderrLine: ((String) -> Void)? = nil) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        lock.lock()
        if cancelledFlag {
            lock.unlock()
            throw FlipError.cancelled
        }
        current = process
        lock.unlock()

        do {
            try process.run()
        } catch {
            lock.lock()
            current = nil
            lock.unlock()
            throw FlipError.failed("Impossibile avviare \(executable.lastPathComponent): \(error.localizedDescription)")
        }

        // Se l'annullamento è arrivato proprio mentre il processo partiva, lo si ferma subito.
        if isCancelled {
            process.terminate()
        }

        let readers = DispatchGroup()
        let errors = ErrorBuffer()

        DispatchQueue.global(qos: .utility).async(group: readers) {
            ProcessRunner.drain(outPipe.fileHandleForReading, onChunk: nil, onLine: onStdoutLine)
        }
        DispatchQueue.global(qos: .utility).async(group: readers) {
            ProcessRunner.drain(errPipe.fileHandleForReading, onChunk: { errors.append($0) }, onLine: onStderrLine)
        }

        process.waitUntilExit()
        _ = readers.wait(timeout: .now() + 10)

        lock.lock()
        current = nil
        let wasCancelled = cancelledFlag
        lock.unlock()

        if wasCancelled { throw FlipError.cancelled }

        let errorText = errors.text
        if process.terminationStatus != 0 {
            let tail = errorText.trimmingCharacters(in: .whitespacesAndNewlines)
            var message = "\(executable.lastPathComponent) è terminato con errore (codice \(process.terminationStatus))."
            if !tail.isEmpty {
                message += "\n" + String(tail.suffix(1500))
            }
            throw FlipError.failed(message)
        }
        return errorText
    }

    /// Legge una pipe fino alla fine: passa ogni blocco a `onChunk` e ogni riga completa a `onLine`.
    private static func drain(_ handle: FileHandle, onChunk: ((Data) -> Void)?, onLine: ((String) -> Void)?) {
        var pending = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            onChunk?(chunk)
            guard let onLine = onLine else { continue }
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...newline)
                onLine(line)
            }
        }
    }
}
