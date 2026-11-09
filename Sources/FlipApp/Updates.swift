import Foundation

/// Informazioni scritte da build-app.sh nell'Info.plist dell'app (da quale cartella e da quale commit è stata creata).
struct BuildInfo: Sendable {
    let version: String
    let commit: String?
    let branch: String?
    let sourceDirectory: String?

    static var current: BuildInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        func value(_ key: String) -> String? {
            guard let text = (info[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                return nil
            }
            return text
        }
        return BuildInfo(
            version: value("CFBundleShortVersionString") ?? "?",
            commit: value("FlipMacCommit"),
            branch: value("FlipMacBranch"),
            sourceDirectory: value("FlipMacSourceDir")
        )
    }

    /// Gli aggiornamenti funzionano se l'app è stata compilata da una repo git (con un commit).
    var canUpdate: Bool {
        guard let directory = sourceDirectory, commit != nil else { return false }
        return FileManager.default.fileExists(atPath: directory + "/.git")
    }

    var shortCommit: String? {
        return commit.map { String($0.prefix(7)) }
    }
}

enum UpdateResult: Sendable {
    case upToDate
    case available(newCommits: Int)
    case notConfigured
    case failed(String)
}

/// Controllo e installazione degli aggiornamenti dalla repo GitHub, con il `git` del Mac
/// (quindi funziona anche con una repo privata, con le credenziali già salvate).
enum Updater {
    static let logURL = FlipLog.url.deletingLastPathComponent().appendingPathComponent("update.log")

    /// Bloccante (rete): da chiamare fuori dal thread principale.
    static func check(_ build: BuildInfo) -> UpdateResult {
        guard build.canUpdate, let directory = build.sourceDirectory, let commit = build.commit else {
            return .notConfigured
        }
        let branch = build.branch ?? "main"

        let fetch = git(["-C", directory, "fetch", "--quiet", "origin", branch], timeout: 60)
        guard fetch.status == 0 else {
            let reason = fetch.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = reason.lowercased()
            if lower.contains("could not read username") || lower.contains("authentication failed")
                || lower.contains("permission denied") || lower.contains("repository not found") {
                return .failed("GitHub chiede le credenziali (repo privata?). Esegui una volta nel Terminale:\n\ncd \(directory) && git fetch\n\ne accedi: le credenziali restano nel Portachiavi e poi il controllo funziona da solo.")
            }
            if lower.contains("could not resolve host") || lower.contains("unable to access") {
                return .failed("GitHub non è raggiungibile: controlla la connessione e riprova.")
            }
            return .failed(reason.isEmpty ? "git fetch non è riuscito." : String(reason.suffix(400)))
        }
        // Modifiche presenti su GitHub e non ancora nell'app installata.
        let count = git(["-C", directory, "rev-list", "--count", "\(commit)..origin/\(branch)"], timeout: 20)
        guard count.status == 0, let number = Int(count.output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .failed("Impossibile confrontare la versione installata con quella su GitHub.")
        }
        return number == 0 ? .upToDate : .available(newCommits: number)
    }

    /// Bloccante: scarica, ricompila e reinstalla con scripts/update.sh. Restituisce true se è andato tutto bene.
    static func install(_ build: BuildInfo, intoApplications: Bool) -> Bool {
        guard let directory = build.sourceDirectory else { return false }
        let script = directory + "/scripts/update.sh"
        guard FileManager.default.isExecutableFile(atPath: script) || FileManager.default.fileExists(atPath: script) else {
            return false
        }

        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        guard let log = try? FileHandle(forWritingTo: logURL) else { return false }
        defer { try? log.close() }
        _ = try? log.seekToEnd()
        try? log.write(contentsOf: Data("\n=== Aggiornamento \(Date()) ===\n".utf8))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script] + (intoApplications ? ["--install"] : [])
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = environment()
        process.standardOutput = log
        process.standardError = log
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    // MARK: - Utilità

    /// Le app avviate dal Finder hanno un PATH minimo: si aggiungono le cartelle di Homebrew.
    private static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let extra = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = extra + ":" + (environment["PATH"] ?? "")
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes -o ConnectTimeout=15"
        return environment
    }

    private static func git(_ arguments: [String], timeout: TimeInterval) -> (status: Int32, output: String) {
        let candidates = ["/usr/bin/git", "/opt/homebrew/bin/git", "/usr/local/bin/git"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return (-1, "git non trovato.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = environment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }

        // Lettura in un thread a parte, con un tempo massimo: senza rete git potrebbe restare in attesa.
        let done = DispatchSemaphore(value: 0)
        let box = OutputBox()
        DispatchQueue.global(qos: .utility).async {
            box.data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = done.wait(timeout: .now() + 5)
            return (-1, "Tempo scaduto: GitHub non risponde (connessione assente?).")
        }
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: box.data, as: UTF8.self))
    }

    private final class OutputBox: @unchecked Sendable {
        var data = Data()
    }
}
