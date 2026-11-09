import Foundation

/// Utilità per i file firmati digitalmente .p7m (busta CAdES/CMS con il documento originale dentro).
enum SignedFile {
    private static let signatureExtension = "p7m"

    /// Nome senza le estensioni della firma: "atto.pdf.p7m" → "atto.pdf"; "atto.pdf.p7m.p7m" → "atto.pdf".
    static func unsignedName(of url: URL) -> String {
        var name = url.lastPathComponent
        while (name as NSString).pathExtension.lowercased() == signatureExtension {
            name = (name as NSString).deletingPathExtension
        }
        return name
    }

    /// Formato del documento firmato secondo il nome: "fattura.xml.p7m" → "xml"; "atto.p7m" → nil.
    static func innerExtension(of url: URL) -> String? {
        let inner = FlipFormat.normalize((unsignedName(of: url) as NSString).pathExtension)
        guard !inner.isEmpty, FlipFormat.category(of: inner) != nil else { return nil }
        return inner
    }

    /// Nome di base per il file estratto: "atto.pdf.p7m" → "atto"; "atto.p7m" → "atto".
    static func baseName(of url: URL) -> String {
        let name = unsignedName(of: url)
        return innerExtension(of: url) == nil ? name : (name as NSString).deletingPathExtension
    }

    /// Formato riconosciuto dai primi byte del contenuto (nil se non si capisce: si usa il nome).
    static func sniff(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(16))
        func starts(_ prefix: [UInt8]) -> Bool {
            return bytes.count >= prefix.count && Array(bytes[0..<prefix.count]) == prefix
        }
        if starts([0x25, 0x50, 0x44, 0x46]) { return "pdf" }          // %PDF
        if starts([0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if starts([0xFF, 0xD8, 0xFF]) { return "jpg" }
        if starts([0x7B, 0x5C, 0x72, 0x74, 0x66]) { return "rtf" }    // {\rtf
        if starts([0x50, 0x4B, 0x03, 0x04]) { return nil }             // zip: docx, odt… (si usa il nome)
        var text = String(decoding: data.prefix(256), as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let head = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if head.hasPrefix("<?xml") || head.hasPrefix("<") { return "xml" }
        return nil
    }

    /// Una busta CMS in DER comincia con una SEQUENCE (0x30).
    static func isDER(_ data: Data) -> Bool {
        return data.first == 0x30
    }

    /// Alcuni programmi salvano il .p7m in Base64 (a volte con intestazioni PEM): lo si riporta in DER.
    static func der(from data: Data) -> Data {
        if isDER(data) { return data }
        let text = String(decoding: data, as: UTF8.self)
        let cleaned = text
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let decoded = Data(base64Encoded: cleaned, options: .ignoreUnknownCharacters), isDER(decoded) {
            return decoded
        }
        return data
    }
}
