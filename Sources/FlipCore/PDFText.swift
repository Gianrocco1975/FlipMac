import Foundation
import CoreGraphics
import CoreText

/// Crea un PDF A4 a partire da testo semplice, con impaginazione automatica (Core Text).
enum PDFText {
    static func write(text: String, to url: URL, monospaced: Bool) throws {
        let pageWidth: CGFloat = 595.28
        let pageHeight: CGFloat = 841.89
        let margin: CGFloat = 54

        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw FlipError.failed("Impossibile creare il PDF.")
        }

        let font = CTFontCreateWithName((monospaced ? "Menlo" : "Helvetica") as CFString, monospaced ? 9 : 11, nil)
        let attributes: [CFString: Any] = [kCTFontAttributeName: font]
        guard let attributed = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary) else {
            throw FlipError.failed("Impossibile preparare il testo per il PDF.")
        }

        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let textLength = CFAttributedStringGetLength(attributed)
        let textRect = CGRect(x: margin, y: margin, width: pageWidth - 2 * margin, height: pageHeight - 2 * margin)
        let path = CGPath(rect: textRect, transform: nil)

        var position: CFIndex = 0
        repeat {
            context.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: position, length: 0), path, nil)
            CTFrameDraw(frame, context)
            let visible = CTFrameGetVisibleStringRange(frame)
            context.endPDFPage()
            if visible.length == 0 { break }
            position += visible.length
        } while position < textLength

        context.closePDF()
    }
}
