import Foundation

enum TextIO {
    static func read(_ url: URL) throws -> String {
        var encoding = String.Encoding.utf8
        if let text = try? String(contentsOf: url, usedEncoding: &encoding) {
            return text
        }
        if let text = try? String(contentsOf: url, encoding: .isoLatin1) {
            return text
        }
        throw FlipError.failed("Impossibile leggere il file come testo.")
    }

    static func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: false, encoding: .utf8)
    }
}
