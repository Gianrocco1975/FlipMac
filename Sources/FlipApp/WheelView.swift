import AppKit
import FlipCore

/// Ruota radiale: un settore per ogni formato. Durante la conversione diventa un anello di avanzamento.
@MainActor
final class WheelView: NSView {
    enum Mode {
        case choosing
        case converting
        case finished(success: Bool, message: String)
    }

    var formats: [String] = [] { didSet { needsDisplay = true } }
    var title = "" { didSet { needsDisplay = true } }
    var subtitle = "" { didSet { needsDisplay = true } }
    var mode: Mode = .choosing { didSet { needsDisplay = true } }
    var progress: Double = 0 { didSet { needsDisplay = true } }
    var innerRadius: CGFloat = 58
    var outerRadius: CGFloat = 150
    /// Ruota aperta col gesto ↓: si sceglie il formato rilasciando i file sul settore.
    var dropMode = false { didSet { needsDisplay = true } }

    var onSelect: ((String) -> Void)?
    var onDrop: ((String, [URL]) -> Void)?
    var onCancel: (() -> Void)?

    private var highlighted: Int? {
        didSet {
            if oldValue != highlighted { needsDisplay = true }
        }
    }
    private var trackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    // MARK: - Eventi

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = trackingArea {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard case .choosing = mode else { return }
        highlighted = index(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        highlighted = nil
    }

    override func mouseDown(with event: NSEvent) {
        guard case .choosing = mode else { return }
        if let selected = index(at: convert(event.locationInWindow, from: nil)) {
            onSelect?(formats[selected])
        } else {
            onCancel?()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: - Rilascio dei file (gesto ↓)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return dragOperation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return dragOperation(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        highlighted = nil
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard case .choosing = mode else { return false }
        return index(at: convert(sender.draggingLocation, from: nil)) != nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard case .choosing = mode,
              let selected = index(at: convert(sender.draggingLocation, from: nil)) else { return false }
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) ?? [])
            .compactMap { $0 as? URL }
        highlighted = nil
        onDrop?(formats[selected], urls)
        return true
    }

    /// Sopra un settore il rilascio è permesso (copia); al centro o fuori no, e i file tornano al loro posto.
    private func dragOperation(for sender: NSDraggingInfo) -> NSDragOperation {
        guard case .choosing = mode else { return [] }
        let selected = index(at: convert(sender.draggingLocation, from: nil))
        highlighted = selected
        return selected == nil ? [] : .copy
    }

    /// Settore sotto il punto indicato (nil se fuori dall'anello).
    private func index(at point: NSPoint) -> Int? {
        guard !formats.isEmpty else { return nil }
        let dx = point.x - bounds.midX
        let dy = point.y - bounds.midY
        let distance = (dx * dx + dy * dy).squareRoot()
        guard distance >= innerRadius, distance <= outerRadius + 6 else { return nil }
        let angle = atan2(dy, dx) * 180 / .pi
        var fromTop = (90 - angle).truncatingRemainder(dividingBy: 360)
        if fromTop < 0 { fromTop += 360 }
        let step = 360 / CGFloat(formats.count)
        return min(Int(fromTop / step), formats.count - 1)
    }

    // MARK: - Disegno

    override func draw(_ dirtyRect: NSRect) {
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        switch mode {
        case .choosing:
            drawWheel(center)
        case .converting:
            drawProgress(center, result: nil, message: "")
        case .finished(let success, let message):
            drawProgress(center, result: success, message: message)
        }
    }

    private func drawWheel(_ center: NSPoint) {
        drawBackgroundDisc(center, radius: outerRadius + 4)

        let count = max(formats.count, 1)
        let step = 360 / CGFloat(count)
        let gap: CGFloat = count > 1 ? 1.2 : 0
        let labelSize: CGFloat = count > 10 ? 11 : 13

        for (position, format) in formats.enumerated() {
            let start = 90 - CGFloat(position) * step - gap / 2
            let end = 90 - CGFloat(position + 1) * step + gap / 2

            let path = NSBezierPath()
            path.appendArc(withCenter: center, radius: outerRadius, startAngle: start, endAngle: end, clockwise: true)
            path.appendArc(withCenter: center, radius: innerRadius + 4, startAngle: end, endAngle: start, clockwise: false)
            path.close()

            let isHot = highlighted == position
            segmentColor(for: format, position: position, hot: isHot).setFill()
            path.fill()

            let middle = (start + end) / 2 * .pi / 180
            let radius = (outerRadius + innerRadius + 4) / 2
            let point = NSPoint(x: center.x + cos(middle) * radius, y: center.y + sin(middle) * radius)
            drawCentered(format.uppercased(), at: point, size: labelSize, weight: .semibold,
                         color: isHot ? .white : .labelColor)
        }

        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(ovalIn: circle(center, innerRadius)).fill()
        drawCentered(title, at: NSPoint(x: center.x, y: center.y + 8), size: 11, weight: .medium,
                     color: .labelColor, maxWidth: innerRadius * 1.7)
        drawCentered(dropMode ? "Rilascia su un formato" : "Esc per uscire",
                     at: NSPoint(x: center.x, y: center.y - 12), size: 9, weight: .regular,
                     color: .secondaryLabelColor)
    }

    private func drawProgress(_ center: NSPoint, result: Bool?, message: String) {
        let ringRadius = innerRadius + 30
        drawBackgroundDisc(center, radius: ringRadius + 26)

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: ringRadius, startAngle: 0, endAngle: 360)
        track.lineWidth = 12
        NSColor.labelColor.withAlphaComponent(0.1).setStroke()
        track.stroke()

        let value = result == nil ? min(max(progress, 0), 1) : 1
        if value > 0 {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: ringRadius, startAngle: 90,
                          endAngle: 90 - 360 * CGFloat(value), clockwise: true)
            arc.lineWidth = 12
            arc.lineCapStyle = .round
            (result == false ? NSColor.systemRed : NSColor.controlAccentColor).setStroke()
            arc.stroke()
        }

        if let success = result {
            drawCentered(success ? "✓" : "✕", at: NSPoint(x: center.x, y: center.y + 10), size: 34, weight: .bold,
                         color: success ? .controlAccentColor : .systemRed)
            drawCentered(message, at: NSPoint(x: center.x, y: center.y - 22), size: 11, weight: .medium,
                         color: .labelColor, maxWidth: ringRadius * 1.5)
        } else {
            let percent = Int((min(max(progress, 0), 1) * 100).rounded())
            drawCentered("\(percent)%", at: NSPoint(x: center.x, y: center.y + 10), size: 26, weight: .semibold,
                         color: .labelColor)
            drawCentered(subtitle, at: NSPoint(x: center.x, y: center.y - 16), size: 11, weight: .medium,
                         color: .secondaryLabelColor, maxWidth: ringRadius * 1.5)
            drawCentered("Esc annulla", at: NSPoint(x: center.x, y: center.y - 32), size: 9, weight: .regular,
                         color: .tertiaryLabelColor)
        }
    }

    private func drawBackgroundDisc(_ center: NSPoint, radius: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 14
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.set()
        NSColor.windowBackgroundColor.withAlphaComponent(0.97).setFill()
        NSBezierPath(ovalIn: circle(center, radius)).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// I formati audio (ad esempio l'estrazione da un video) hanno una tinta diversa.
    private func segmentColor(for format: String, position: Int, hot: Bool) -> NSColor {
        if hot { return .controlAccentColor }
        if FlipFormat.category(of: format) == .audio {
            return NSColor.systemPurple.withAlphaComponent(position % 2 == 0 ? 0.16 : 0.22)
        }
        return NSColor.labelColor.withAlphaComponent(position % 2 == 0 ? 0.06 : 0.10)
    }

    private func circle(_ center: NSPoint, _ radius: CGFloat) -> NSRect {
        return NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }

    private func drawCentered(_ text: String, at point: NSPoint, size: CGFloat, weight: NSFont.Weight,
                              color: NSColor, maxWidth: CGFloat? = nil) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color
        ]
        var display = text
        if let maxWidth = maxWidth {
            let characters = Array(text)
            var keep = characters.count
            while keep > 4, (display as NSString).size(withAttributes: attributes).width > maxWidth {
                keep -= 1
                let head = keep / 2
                let tail = keep - head
                display = String(characters.prefix(head)) + "…" + String(characters.suffix(tail))
            }
        }
        let measured = (display as NSString).size(withAttributes: attributes)
        let origin = NSPoint(x: point.x - measured.width / 2, y: point.y - measured.height / 2)
        (display as NSString).draw(at: origin, withAttributes: attributes)
    }
}
