import Foundation

/// Trova gli strumenti esterni (ffmpeg, pandoc, LibreOffice...).
/// Le app grafiche su macOS hanno un PATH minimo, quindi si cercano anche le cartelle di Homebrew.
public enum ToolLocator {
    private static let extraDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        NSHomeDirectory() + "/.homebrew/bin",
        NSHomeDirectory() + "/homebrew/bin",
        "/opt/local/bin",
        "/usr/bin",
        "/bin",
        "/Applications/LibreOffice.app/Contents/MacOS",
        "/Library/TeX/texbin",
        NSHomeDirectory() + "/.local/bin"
    ]

    /// Motori PDF che pandoc può usare, in ordine di preferenza.
    private static let pdfEngines = ["weasyprint", "wkhtmltopdf", "typst", "tectonic", "xelatex", "lualatex", "pdflatex"]

    public static func find(_ name: String) -> URL? {
        var directories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        directories.append(contentsOf: extraDirectories)
        for directory in directories {
            let path = directory + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    public static func firstPDFEngine() -> URL? {
        for name in pdfEngines {
            if let url = find(name) { return url }
        }
        return nil
    }
}
