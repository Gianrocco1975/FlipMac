import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Conversioni di immagini con ImageIO (nativo macOS).
/// WebP in uscita: ImageIO se il sistema lo sa scrivere, altrimenti `cwebp` (brew install webp), altrimenti ffmpeg con libwebp.
struct ImageConverter {
    let runner: ProcessRunner

    func convert(input: URL, target: String, output: URL, notes: inout [String]) throws {
        if target == "webp" {
            try writeWebP(
                to: output,
                native: { try self.native(input: input, target: "webp", output: $0) },
                png: { try self.native(input: input, target: "png", output: $0) }
            )
            return
        }
        do {
            try native(input: input, target: target, output: output)
        } catch FlipError.cancelled {
            throw FlipError.cancelled
        } catch {
            guard target != "pdf", ToolLocator.find("ffmpeg") != nil else { throw error }
            notes.append("Lettura nativa non riuscita, ho usato ffmpeg.")
            try viaFFmpeg(input: input, output: output, extra: ["-frames:v", "1"])
        }
    }

    /// Scrive un'immagine già in memoria (usato per le pagine dei PDF).
    func write(_ image: CGImage, target: String, to output: URL) throws {
        if target == "webp" {
            try writeWebP(
                to: output,
                native: { try self.encode(image, target: "webp", to: $0) },
                png: { try self.encode(image, target: "png", to: $0) }
            )
            return
        }
        try encode(image, target: target, to: output)
    }

    // MARK: - WebP

    private func writeWebP(to output: URL, native: (URL) throws -> Void, png: (URL) throws -> Void) throws {
        let writable = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        if writable.contains(UTType.webP.identifier) {
            try native(output)
            return
        }

        // cwebp e ffmpeg leggono bene il PNG: si passa da un PNG temporaneo (già ruotato correttamente).
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("flip-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: temp) }

        if let cwebp = ToolLocator.find("cwebp") {
            try png(temp)
            try runner.run(cwebp, ["-quiet", "-q", "90", temp.path, "-o", output.path])
            return
        }

        if let ffmpeg = ToolLocator.find("ffmpeg"), FFmpegEncoders.available(ffmpeg).contains("libwebp") {
            try png(temp)
            try viaFFmpeg(input: temp, output: output, extra: ["-frames:v", "1", "-c:v", "libwebp", "-quality", "90"])
            return
        }

        throw FlipError.missingTool(name: "cwebp", hint: "Per creare file WebP installa: brew install webp")
    }

    // MARK: - ImageIO

    private func native(input: URL, target: String, output: URL) throws {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil) else {
            throw FlipError.failed("Impossibile leggere l'immagine.")
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0, let upright = uprightFirstImage(source) else {
            throw FlipError.failed("Impossibile decodificare l'immagine.")
        }
        let (first, remainingOrientation) = upright

        // GIF animata → GIF: si copiano tutti i fotogrammi.
        if target == "gif" && count > 1 {
            guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, count, nil) else {
                throw FlipError.failed("Impossibile creare il file di destinazione.")
            }
            for index in 0..<count {
                CGImageDestinationAddImageFromSource(destination, source, index, nil)
            }
            guard CGImageDestinationFinalize(destination) else {
                throw FlipError.failed("Scrittura dell'immagine non riuscita.")
            }
            return
        }

        try encode(first, target: target, to: output, orientation: remainingOrientation)
    }

    /// Scrive una singola immagine nel formato indicato (anche PDF).
    private func encode(_ image: CGImage, target: String, to output: URL, orientation: Int = 1) throws {
        if target == "pdf" {
            try writePDF(image, to: output)
            return
        }

        let type: UTType
        switch target {
        case "png": type = .png
        case "jpg": type = .jpeg
        case "bmp": type = .bmp
        case "tiff": type = .tiff
        case "gif": type = .gif
        case "webp": type = .webP
        default: throw FlipError.unsupported("Formato immagine non supportato: \(target)")
        }

        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil) else {
            throw FlipError.failed("Impossibile creare il file di destinazione.")
        }
        var options: [String: Any] = [:]
        if orientation != 1 {
            options[kCGImagePropertyOrientation as String] = orientation
        }
        if target == "jpg" || target == "webp" {
            options[kCGImageDestinationLossyCompressionQuality as String] = 0.92
        }
        var finalImage = image
        if (target == "jpg" || target == "bmp") && hasAlpha(image) {
            finalImage = flattenOnWhite(image)
        }
        CGImageDestinationAddImage(destination, finalImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw FlipError.failed("Scrittura dell'immagine non riuscita.")
        }
    }

    /// Prima immagine già ruotata secondo l'orientamento EXIF (ad esempio le foto di iPhone),
    /// così il risultato è dritto anche nei formati che non conservano l'orientamento (BMP, GIF, PDF).
    /// Restituisce anche l'orientamento ancora da indicare nei metadati (1 = nessuno).
    private func uprightFirstImage(_ source: CGImageSource) -> (CGImage, Int)? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        let orientation = (properties?[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1

        if orientation != 1,
           let width = (properties?[kCGImagePropertyPixelWidth as String] as? NSNumber)?.intValue,
           let height = (properties?[kCGImagePropertyPixelHeight as String] as? NSNumber)?.intValue {
            let options: [String: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways as String: true,
                kCGImageSourceCreateThumbnailWithTransform as String: true,
                kCGImageSourceShouldCacheImmediately as String: true,
                kCGImageSourceThumbnailMaxPixelSize as String: max(width, height)
            ]
            if let rotated = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return (rotated, 1)
            }
        }

        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return (image, orientation)
    }

    private func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        default:
            return true
        }
    }

    /// JPG e BMP non hanno trasparenza: si appoggia l'immagine su fondo bianco.
    private func flattenOnWhite(_ image: CGImage) -> CGImage {
        let width = image.width
        let height = image.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return image
        }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage() ?? image
    }

    private func writePDF(_ image: CGImage, to output: URL) throws {
        var box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let context = CGContext(output as CFURL, mediaBox: &box, nil) else {
            throw FlipError.failed("Impossibile creare il PDF.")
        }
        context.beginPDFPage(nil)
        context.draw(image, in: box)
        context.endPDFPage()
        context.closePDF()
    }

    private func viaFFmpeg(input: URL, output: URL, extra: [String]) throws {
        guard let ffmpeg = ToolLocator.find("ffmpeg") else {
            throw FlipError.missingTool(name: "ffmpeg", hint: "Per questo formato serve ffmpeg: brew install ffmpeg")
        }
        let arguments = ["-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-i", input.path] + extra + [output.path]
        try runner.run(ffmpeg, arguments)
    }
}
