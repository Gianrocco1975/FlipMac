import Foundation
import FlipCore

let version = "0.4.0"

func eprint(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func printUsage() {
    print("""
    flip \(version) — convertitore di file locale per macOS

    USO
      flip <file> [<file> ...] --to <formato>   converte uno o più file
      flip --formats [<estensione>]             mostra i formati disponibili
      flip --doctor                             controlla gli strumenti installati

    ESEMPI
      flip video.mov --to mp4
      flip *.png --to jpg
      flip dati.json --to csv

    La copia convertita viene creata accanto all'originale: nessun file viene sovrascritto.
    """)
}

func printDoctor() {
    let tools: [(name: String, hint: String)] = [
        ("ffmpeg", "brew install ffmpeg"),
        ("ffprobe", "incluso con ffmpeg"),
        ("pandoc", "brew install pandoc"),
        ("soffice", "brew install --cask libreoffice"),
        ("cwebp", "brew install webp — serve per creare file WebP"),
        ("pdf2docx", "brew install pipx && pipx install pdf2docx — PDF → Word fedele"),
        ("textutil", "incluso in macOS")
    ]
    for tool in tools {
        if let url = ToolLocator.find(tool.name) {
            print("✓ \(tool.name): \(url.path)")
        } else {
            print("✗ \(tool.name): non trovato (\(tool.hint))")
        }
    }
    if let ffmpeg = ToolLocator.find("ffmpeg") {
        let encoders = FFmpegEncoders.available(ffmpeg)
        let wanted: [(name: String, purpose: String)] = [
            ("libx264", "MP4, MKV, MOV, M4V"),
            ("libvpx-vp9", "WebM"),
            ("libmp3lame", "MP3"),
            ("libopus", "Opus e audio WebM"),
            ("libvorbis", "OGG; se manca uso il Vorbis interno"),
            ("libwebp", "WebP; se manca uso cwebp")
        ]
        print("  Encoder di ffmpeg:")
        for encoder in wanted {
            let mark = encoders.contains(encoder.name) ? "✓" : "•"
            let state = encoders.contains(encoder.name) ? "presente" : "assente"
            print("    \(mark) \(encoder.name) \(state) (\(encoder.purpose))")
        }
    }
    if let engine = ToolLocator.firstPDFEngine() {
        print("✓ motore PDF per pandoc: \(engine.path)")
    } else {
        print("• motore PDF per pandoc: nessuno (facoltativo: brew install weasyprint)")
    }
    print("")
    print("Senza strumenti esterni funzionano: JSON/YAML/XML/CSV, immagini (PNG, JPG, BMP, TIFF, GIF, HEIC), PDF di testo e PDF → immagini o testo.")
}

func printFormats(_ ext: String?) {
    if let ext = ext {
        let targets = FlipFormat.targets(for: ext)
        if targets.isEmpty {
            eprint("Formato non supportato: \(ext)")
            exit(2)
        }
        print("\(FlipFormat.normalize(ext)) → \(targets.joined(separator: ", "))")
        return
    }
    print("Video:    \(FlipFormat.video.joined(separator: ", "))")
    print("Audio:    \(FlipFormat.audio.joined(separator: ", "))")
    print("Immagini: \(FlipFormat.image.joined(separator: ", ")) (anche HEIC in ingresso)")
    print("Dati:     \(FlipFormat.structured.joined(separator: ", ")) → anche txt, html, md, pdf")
    print("Testi:    \(FlipFormat.document.joined(separator: ", ")) → anche pdf")
    print("PDF:      → \(FlipFormat.pdfImageTargets.joined(separator: ", ")) (pagine come immagini), \(FlipFormat.pdfTextTargets.joined(separator: ", ")) (documenti)")
    print("Firmati:  p7m → pdf, oppure il documento originale (es. fattura.xml.p7m → xml)")
}

// MARK: - Argomenti

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.isEmpty {
    printUsage()
    exit(1)
}
if arguments.contains("-h") || arguments.contains("--help") {
    printUsage()
    exit(0)
}
if arguments[0] == "--doctor" {
    printDoctor()
    exit(0)
}
if arguments[0] == "--formats" {
    printFormats(arguments.count > 1 ? arguments[1] : nil)
    exit(0)
}

var files = [String]()
var target: String?
var position = 0
while position < arguments.count {
    let argument = arguments[position]
    if argument == "--to" || argument == "-t" {
        position += 1
        guard position < arguments.count else {
            eprint("Manca il formato dopo \(argument).")
            exit(2)
        }
        target = arguments[position]
    } else if argument.hasPrefix("--to=") {
        target = String(argument.dropFirst(5))
    } else {
        files.append(argument)
    }
    position += 1
}

if files.isEmpty {
    eprint("Nessun file indicato.")
    printUsage()
    exit(2)
}

guard let targetFormat = target else {
    for file in files {
        let url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
        let available = FlipFormat.targets(for: url)
        if available.isEmpty {
            print("\(file): formato non supportato")
        } else {
            print("\(file) → \(available.joined(separator: ", "))")
        }
    }
    print("Aggiungi --to <formato> per convertire.")
    exit(0)
}

// MARK: - Conversione

let converter = Converter()
signal(SIGINT, SIG_IGN)
let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: DispatchQueue.global())
interruptSource.setEventHandler { converter.cancel() }
interruptSource.resume()

let showProgress = isatty(STDERR_FILENO) != 0
var failures = 0

for path in files {
    let expanded = (path as NSString).expandingTildeInPath
    let url = URL(fileURLWithPath: expanded)
    let name = url.lastPathComponent
    do {
        let result = try converter.convert(input: url, to: targetFormat) { fraction in
            if showProgress {
                let percent = Int((fraction * 100).rounded())
                FileHandle.standardError.write(Data("\r  \(name): \(percent)%   ".utf8))
            }
        }
        if showProgress { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) }
        for output in result.outputs {
            print("✓ \(output.path)")
        }
        for note in result.notes {
            eprint("  ! \(note)")
        }
    } catch {
        if showProgress { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) }
        failures += 1
        eprint("✗ \(name): \(error.localizedDescription)")
        if let flipError = error as? FlipError, case .cancelled = flipError {
            break
        }
    }
}

exit(failures == 0 ? 0 : 1)
