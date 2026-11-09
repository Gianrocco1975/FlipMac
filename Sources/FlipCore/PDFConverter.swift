import Foundation
import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Conversioni da PDF:
/// - pagine come immagini (PNG, JPG, WebP: un file per pagina; TIFF: un unico file con tutte le pagine), nativo;
/// - documenti (DOCX, ODT, RTF, HTML, TXT, Markdown): ricostruiti con pdf2docx se installato,
///   altrimenti solo il testo estratto con PDFKit.
struct PDFConverter {
    let runner: ProcessRunner

    /// Risoluzione delle immagini e lato massimo in pixel (per non creare immagini enormi da tavole grandi).
    private static let dpi: CGFloat = 150
    private static let maxSide: CGFloat = 6000

    /// Restituisce i file temporanei creati (più di uno se le pagine diventano immagini separate).
    func convert(input: URL, target: String, output: URL, progress: ((Double) -> Void)?, notes: inout [String]) throws -> [URL] {
        if FlipFormat.pdfImageTargets.contains(target) {
            return try renderPages(input: input, target: target, output: output, progress: progress, notes: &notes)
        }
        try extractText(input: input, target: target, output: output, progress: progress, notes: &notes)
        return [output]
    }

    // MARK: - Pagine → immagini

    private func renderPages(input: URL, target: String, output: URL, progress: ((Double) -> Void)?,
                             notes: inout [String]) throws -> [URL] {
        guard let document = CGPDFDocument(input as CFURL) else {
            throw FlipError.failed("Impossibile aprire il PDF.")
        }
        if document.isEncrypted && !document.isUnlocked && !document.unlockWithPassword("") {
            throw FlipError.failed("Il PDF è protetto da password.")
        }
        let count = document.numberOfPages
        guard count > 0 else {
            throw FlipError.failed("Il PDF non ha pagine.")
        }

        // TIFF: tutte le pagine in un solo file, aggiunte una alla volta per non occupare troppa memoria.
        if target == "tiff" {
            guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.tiff.identifier as CFString, count, nil) else {
                throw FlipError.failed("Impossibile creare il file TIFF.")
            }
            let options: [String: Any] = [
                kCGImagePropertyTIFFDictionary as String: [kCGImagePropertyTIFFCompression as String: 5]
            ]
            for number in 1...count {
                if runner.isCancelled { throw FlipError.cancelled }
                let image = try render(page: document.page(at: number), number: number)
                CGImageDestinationAddImage(destination, image, options as CFDictionary)
                progress?(Double(number) / Double(count) * 0.99)
            }
            guard CGImageDestinationFinalize(destination) else {
                throw FlipError.failed("Scrittura del TIFF non riuscita.")
            }
            if count > 1 {
                notes.append("Creato un unico TIFF con tutte le \(count) pagine.")
            }
            return [output]
        }

        let images = ImageConverter(runner: runner)
        if count == 1 {
            try images.write(try render(page: document.page(at: 1), number: 1), target: target, to: output)
            return [output]
        }

        // Più pagine: un file per pagina.
        var written = [URL]()
        do {
            for number in 1...count {
                if runner.isCancelled { throw FlipError.cancelled }
                let pageURL = Self.pageURL(for: output, number: number)
                try images.write(try render(page: document.page(at: number), number: number), target: target, to: pageURL)
                written.append(pageURL)
                progress?(Double(number) / Double(count) * 0.99)
            }
        } catch {
            for url in written {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }
        return written
    }

    /// Disegna una pagina su fondo bianco, rispettando ritaglio e rotazione.
    private func render(page: CGPDFPage?, number: Int) throws -> CGImage {
        guard let page = page else {
            throw FlipError.failed("Impossibile leggere la pagina \(number) del PDF.")
        }
        let box = page.getBoxRect(.cropBox)
        let rotation = ((Int(page.rotationAngle) % 360) + 360) % 360
        let size = (rotation == 90 || rotation == 270)
            ? CGSize(width: box.height, height: box.width)
            : box.size
        guard size.width > 0, size.height > 0 else {
            throw FlipError.failed("La pagina \(number) del PDF è vuota.")
        }

        let scale = min(Self.dpi / 72, Self.maxSide / max(size.width, size.height))
        let width = max(Int((size.width * scale).rounded()), 1)
        let height = max(Int((size.height * scale).rounded()), 1)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw FlipError.failed("Memoria insufficiente per la pagina \(number).")
        }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
        // Trasformazione a scala 1 che porta il ritaglio della pagina nell'area, con la rotazione della pagina.
        let transform = page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size),
                                                 rotate: 0, preserveAspectRatio: true)
        context.concatenate(transform)
        context.drawPDFPage(page)

        guard let image = context.makeImage() else {
            throw FlipError.failed("Impossibile disegnare la pagina \(number).")
        }
        return image
    }

    private static func pageURL(for output: URL, number: Int) -> URL {
        let stem = output.deletingPathExtension().lastPathComponent
        return output.deletingLastPathComponent()
            .appendingPathComponent("\(stem)-\(number).\(output.pathExtension)")
    }

    // MARK: - Testo

    private func extractText(input: URL, target: String, output: URL, progress: ((Double) -> Void)?,
                             notes: inout [String]) throws {
        guard let document = PDFDocument(url: input) else {
            throw FlipError.failed("Impossibile aprire il PDF.")
        }
        if document.isLocked && !document.unlock(withPassword: "") {
            throw FlipError.failed("Il PDF è protetto da password.")
        }

        var pages = [String]()
        for index in 0..<document.pageCount {
            if runner.isCancelled { throw FlipError.cancelled }
            let text = document.page(at: index)?.string ?? ""
            pages.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard pages.contains(where: { !$0.isEmpty }) else {
            throw FlipError.failed("Il PDF non contiene testo selezionabile (probabilmente è una scansione). Puoi convertirlo in immagini: PNG, JPG o TIFF.")
        }

        // Ricostruzione fedele (titoli, grassetti, elenchi, tabelle) se pdf2docx è installato.
        if PDFDocx.isAvailable {
            do {
                try PDFDocx(runner: runner).convert(input: input, target: target, output: output,
                                                    progress: progress, notes: &notes)
                return
            } catch FlipError.cancelled {
                throw FlipError.cancelled
            } catch {
                try? FileManager.default.removeItem(at: output)
                notes.append("pdf2docx non è riuscito a ricostruire il documento (\(error.localizedDescription)): ho estratto solo il testo.")
            }
        } else {
            notes.append("Dal PDF è stato estratto solo il testo: impaginazione, tabelle e immagini non vengono conservate. Per un documento fedele installa pdf2docx: brew install pipx && pipx install pdf2docx")
        }

        let title = input.deletingPathExtension().lastPathComponent
        let plain = pages.joined(separator: "\n\n")

        switch target {
        case "txt":
            try TextIO.write(plain + "\n", to: output)
        case "md":
            try TextIO.write(pages.joined(separator: "\n\n---\n\n") + "\n", to: output)
        case "html":
            try TextIO.write(html(pages: pages, title: title), to: output)
        case "docx", "rtf", "odt":
            guard let textutil = ToolLocator.find("textutil") else {
                throw FlipError.missingTool(name: "textutil", hint: "textutil è incluso in macOS.")
            }
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("flip-\(UUID().uuidString).txt")
            defer { try? FileManager.default.removeItem(at: temp) }
            try TextIO.write(plain + "\n", to: temp)
            try runner.run(textutil, ["-convert", target, "-inputencoding", "UTF-8", "-output", output.path, temp.path])
        default:
            throw FlipError.unsupported("Da PDF non si può convertire in .\(target)")
        }
    }

    private func html(pages: [String], title: String) -> String {
        func escape(_ text: String) -> String {
            return text
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        var body = ""
        for (index, page) in pages.enumerated() {
            body += "<section>\n<h2>Pagina \(index + 1)</h2>\n"
            let paragraphs = page.components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            for paragraph in paragraphs {
                body += "<p>" + escape(paragraph).replacingOccurrences(of: "\n", with: "<br>\n") + "</p>\n"
            }
            body += "</section>\n"
        }
        return """
        <!DOCTYPE html>
        <html lang="it">
        <head>
        <meta charset="utf-8">
        <title>\(escape(title))</title>
        <style>body{font-family:-apple-system,Helvetica,Arial,sans-serif;max-width:46rem;margin:2rem auto;line-height:1.5}h2{font-size:.9rem;color:#888;border-top:1px solid #ddd;padding-top:1rem}</style>
        </head>
        <body>
        <h1>\(escape(title))</h1>
        \(body)
        </body>
        </html>

        """
    }
}
