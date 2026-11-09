import Foundation

public enum Category: String, CaseIterable {
    case video, audio, image, structured, document, pdf, signed
}

/// Registro dei formati supportati e delle conversioni possibili.
public enum FlipFormat {
    public static let video = ["mp4", "mkv", "webm", "avi", "mov", "wmv", "m4v"]
    public static let audio = ["mp3", "wav", "flac", "ogg", "m4a", "aac", "wma", "opus"]
    public static let image = ["png", "jpg", "webp", "bmp", "tiff", "gif"]
    public static let structured = ["json", "yaml", "xml", "csv"]
    public static let document = ["txt", "md", "html", "docx", "epub", "odt", "rtf", "fb2", "rst"]

    /// Da PDF: pagine come immagini, oppure il testo estratto.
    public static let pdfImageTargets = ["png", "jpg", "tiff", "webp"]
    public static let pdfTextTargets = ["txt", "docx", "rtf", "odt", "html", "md"]

    /// File firmati digitalmente (busta CAdES): si estrae il documento originale, o lo si trasforma in PDF.
    public static let signed = ["p7m"]

    /// Formati leggibili ma non proposti come destinazione.
    static let imageInputOnly = ["heic"]
    /// Formati in cui si possono esportare i dati strutturati, oltre ai quattro formati dati.
    static let structuredExports = ["txt", "html", "md", "pdf"]

    /// Porta l'estensione in forma canonica (minuscola, senza punto, alias unificati).
    public static func normalize(_ ext: String) -> String {
        var e = ext.lowercased()
        if e.hasPrefix(".") { e.removeFirst() }
        switch e {
        case "yml": return "yaml"
        case "jpeg", "jpe": return "jpg"
        case "tif": return "tiff"
        case "markdown", "mkd": return "md"
        case "htm": return "html"
        case "heif": return "heic"
        default: return e
        }
    }

    public static func category(of ext: String) -> Category? {
        let e = normalize(ext)
        if video.contains(e) { return .video }
        if audio.contains(e) { return .audio }
        if image.contains(e) || imageInputOnly.contains(e) { return .image }
        if structured.contains(e) { return .structured }
        if document.contains(e) { return .document }
        if e == "pdf" { return .pdf }
        if signed.contains(e) { return .signed }
        return nil
    }

    /// Formati verso cui si può convertire un file con questa estensione.
    public static func targets(for ext: String) -> [String] {
        let e = normalize(ext)
        guard let cat = category(of: e) else { return [] }
        switch cat {
        case .video:
            return video.filter { $0 != e } + audio
        case .audio:
            return audio.filter { $0 != e }
        case .image:
            return image.filter { $0 != e } + ["pdf"]
        case .structured:
            return structured.filter { $0 != e } + structuredExports
        case .document:
            return document.filter { $0 != e } + ["pdf"]
        case .pdf:
            return pdfImageTargets + pdfTextTargets
        case .signed:
            return ["pdf"]
        }
    }
}
