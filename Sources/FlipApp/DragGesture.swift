import AppKit
import ApplicationServices

/// Gesto globale, come in FLIP: mentre si trascinano dei file (dal Finder, dalla Scrivania…)
/// la Freccia Giù apre la ruota dei formati sotto il puntatore.
///
/// Usa un "event tap" di macOS, che richiede il permesso Accessibilità. Guarda solo tre cose:
/// pressione e rilascio del tasto sinistro del mouse e tasti premuti. La Freccia Giù viene "trattenuta"
/// solo quando è in corso un trascinamento di file; in tutti gli altri casi arriva normalmente alle app.
/// Le funzioni vengono chiamate sul thread principale (la sorgente è sul run loop principale).
final class DragGesture: @unchecked Sendable {
    var onTrigger: (@Sendable ([URL]) -> Void)?
    var onMouseUp: (@Sendable () -> Void)?
    var onEscape: (@Sendable () -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// Numero di modifiche del pasteboard di trascinamento quando è stato premuto il mouse:
    /// se cambia mentre il tasto è ancora premuto, è iniziato un trascinamento.
    private var dragCountAtMouseDown = -1
    /// Trascinamento per cui la ruota è già stata aperta (per non riaprirla a ogni pressione).
    private var triggeredForCount = -1

    private static let downArrow: Int64 = 125
    private static let escape: Int64 = 53

    static var isTrusted: Bool {
        return AXIsProcessTrusted()
    }

    /// Fa comparire la richiesta di macOS per il permesso Accessibilità.
    static func requestPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    var isRunning: Bool {
        return tap != nil
    }

    /// Restituisce false se macOS non concede l'event tap (permesso Accessibilità mancante).
    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }

        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseDown.rawValue)
            | (CGEventMask(1) << CGEventType.leftMouseUp.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
            let gesture = Unmanaged<DragGesture>.fromOpaque(refcon).takeUnretainedValue()
            return gesture.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        source = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS spegne l'event tap se risponde lentamente: lo si riaccende.
            if let tap = tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }

        case .leftMouseDown:
            dragCountAtMouseDown = NSPasteboard(name: .drag).changeCount

        case .leftMouseUp:
            onMouseUp?()

        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == Self.escape {
                onEscape?()
                break
            }
            guard keyCode == Self.downArrow,
                  CGEventSource.buttonState(.combinedSessionState, button: .left) else { break }

            let pasteboard = NSPasteboard(name: .drag)
            // Tasto del mouse premuto ma nessun trascinamento iniziato: la freccia resta alle app.
            guard pasteboard.changeCount != dragCountAtMouseDown else { break }
            // Freccia tenuta premuta o premuta di nuovo nello stesso trascinamento: si trattiene e basta.
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 || triggeredForCount == pasteboard.changeCount {
                return nil
            }

            let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
            let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: options) ?? [])
                .compactMap { $0 as? URL }
                .filter { !$0.hasDirectoryPath }
            guard !urls.isEmpty else { break }

            triggeredForCount = pasteboard.changeCount
            onTrigger?(urls)
            return nil

        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }
}
