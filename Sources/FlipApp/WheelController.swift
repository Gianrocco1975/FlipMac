import AppKit
import FlipCore

/// Pannello trasparente con la ruota, che compare dove si trova il puntatore.
final class WheelPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Mostra la ruota, avvia la conversione scelta e ne segue l'avanzamento.
/// Due modi di aprirla:
/// - `show(files:)`: file già scelti (icona, menu, "Apri con"); si clicca il formato;
/// - `showForDrag(files:)`: durante un trascinamento (gesto ↓); si rilasciano i file sul formato.
@MainActor
final class WheelController: NSObject, NSWindowDelegate {
    private var panel: WheelPanel?
    private var view: WheelView?
    private var files: [URL] = []
    private var job: ConversionJob?
    private var clickMonitor: Any?
    private var dropMode = false

    // MARK: - Apertura

    func show(files candidates: [URL]) {
        present(candidates, dropMode: false)
    }

    /// Ruota aperta col gesto ↓ mentre si trascinano dei file.
    func showForDrag(files candidates: [URL]) {
        if dropMode && panel != nil && job == nil {
            return
        }
        present(candidates, dropMode: true)
    }

    /// Il tasto del mouse è stato rilasciato: se i file non sono finiti su un formato, la ruota si chiude.
    func dragEnded() {
        guard dropMode, job == nil, let shown = panel else { return }
        Task { @MainActor in
            // Il rilascio sulla ruota (performDragOperation) arriva subito dopo: si aspetta un attimo.
            try? await Task.sleep(nanoseconds: 400_000_000)
            if self.panel === shown && self.job == nil {
                self.close()
            }
        }
    }

    /// Esc durante il trascinamento: il Finder annulla il trascinamento, la ruota si chiude.
    func dragCancelled() {
        if dropMode && job == nil {
            close()
        }
    }

    private func present(_ candidates: [URL], dropMode: Bool) {
        if job != nil {
            NSSound.beep()
            return
        }

        let supported = candidates.filter { FlipFormat.category(of: $0.pathExtension) != nil }
        guard !supported.isEmpty else {
            if dropMode {
                NSSound.beep()
            } else {
                showAlert(title: "Formato non supportato",
                          text: "FlipMac non sa convertire questi file:\n" + names(candidates))
            }
            return
        }
        let formats = commonTargets(supported)
        guard !formats.isEmpty else {
            if dropMode {
                NSSound.beep()
            } else {
                showAlert(title: "Nessun formato in comune",
                          text: "I file scelti non hanno un formato di destinazione in comune. Convertili a gruppi dello stesso tipo.")
            }
            return
        }

        close()
        files = supported
        self.dropMode = dropMode

        let outerRadius: CGFloat = formats.count > 10 ? 175 : 150
        let side = (outerRadius + 28) * 2
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        var origin = NSPoint(x: mouse.x - side / 2, y: mouse.y - side / 2)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - side)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - side)
        }
        let frame = NSRect(origin: origin, size: NSSize(width: side, height: side))

        let panel = WheelPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                               backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.delegate = self

        let view = WheelView(frame: NSRect(origin: .zero, size: frame.size))
        view.outerRadius = outerRadius
        view.formats = formats
        view.title = supported.count == 1 ? supported[0].lastPathComponent : "\(supported.count) file"
        view.dropMode = dropMode
        view.onSelect = { [weak self] format in
            self?.start(format, dropped: [])
        }
        view.onDrop = { [weak self] format, urls in
            self?.start(format, dropped: urls)
        }
        view.onCancel = { [weak self] in
            self?.cancel()
        }

        panel.contentView = view
        self.panel = panel
        self.view = view

        if dropMode {
            // Durante il trascinamento la ruota non prende il fuoco: riceve solo il rilascio dei file.
            view.registerForDraggedTypes([.fileURL])
            panel.orderFrontRegardless()
        } else {
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(view)

            // Un clic in un'altra app chiude la ruota.
            let controller = self
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
                Task { @MainActor in
                    controller.closeIfIdle()
                }
            }
        }
    }

    // MARK: - Conversione

    private func start(_ format: String, dropped: [URL]) {
        guard job == nil, let view = view, let panel = panel else { return }
        removeClickMonitor()

        // File rilasciati sulla ruota: sono quelli del trascinamento (di solito gli stessi già letti).
        let droppedSupported = dropped.filter { FlipFormat.category(of: $0.pathExtension) != nil }
        if !droppedSupported.isEmpty {
            files = droppedSupported
        }

        let job = ConversionJob(files: files, target: format)
        self.job = job
        let count = files.count
        view.mode = .converting
        view.progress = 0
        view.subtitle = count == 1 ? "→ \(format.uppercased())" : "→ \(format.uppercased()) · 1/\(count)"
        FlipLog.write("Conversione di \(count) file in \(format.uppercased())\(dropMode ? " (gesto ↓)" : "")")

        if dropMode {
            // Dopo il rilascio la ruota prende il fuoco, così Esc annulla la conversione.
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(view)
        }

        let controller = self
        DispatchQueue.global(qos: .userInitiated).async {
            let summary = job.run { fraction, index in
                Task { @MainActor in
                    controller.update(job: job, fraction: fraction, index: index, count: count)
                }
            }
            Task { @MainActor in
                controller.finish(job: job, summary: summary)
            }
        }
    }

    private func update(job: ConversionJob, fraction: Double, index: Int, count: Int) {
        guard job === self.job, let view = view else { return }
        view.progress = fraction
        let format = job.target.uppercased()
        view.subtitle = count == 1 ? "→ \(format)" : "→ \(format) · \(index + 1)/\(count)"
    }

    private func finish(job: ConversionJob, summary: ConversionJob.Summary) {
        guard job === self.job else { return }
        self.job = nil

        for output in summary.outputs {
            FlipLog.write("  ✓ \(output.path)")
        }
        for note in summary.notes {
            FlipLog.write("  ! \(note)")
        }
        for failure in summary.failures {
            FlipLog.write("  ✗ \(failure)")
        }
        if summary.cancelled {
            FlipLog.write("  Conversione annullata")
        }

        let success = summary.failures.isEmpty && !summary.cancelled
        let message: String
        if summary.cancelled {
            message = "Annullata"
        } else if summary.failures.isEmpty {
            message = summary.outputs.count == 1 ? "Fatto" : "\(summary.outputs.count) file convertiti"
        } else {
            message = "\(summary.failures.count) non riuscit\(summary.failures.count == 1 ? "a" : "e")"
        }
        view?.mode = .finished(success: success, message: message)

        let shownPanel = panel
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: summary.cancelled ? 500_000_000 : 1_000_000_000)
            if self.panel === shownPanel {
                self.close()
            }
            if !summary.failures.isEmpty {
                let shown = summary.failures.prefix(6).joined(separator: "\n\n")
                let more = summary.failures.count > 6 ? "\n\n…e altri \(summary.failures.count - 6)." : ""
                self.showAlert(title: "Alcune conversioni non sono riuscite",
                               text: shown + more + "\n\nDettagli nel registro (menu FlipMac → Apri registro).")
            }
        }
    }

    // MARK: - Chiusura

    private func cancel() {
        if let job = job {
            job.cancel()
            view?.subtitle = "Annullamento…"
        } else {
            close()
        }
    }

    private func closeIfIdle() {
        if job == nil {
            close()
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        closeIfIdle()
    }

    private func close() {
        removeClickMonitor()
        if let panel = panel {
            panel.delegate = nil
            panel.orderOut(nil)
            panel.close()
        }
        panel = nil
        view = nil
        dropMode = false
    }

    private func removeClickMonitor() {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }

    // MARK: - Utilità

    /// Formati disponibili per tutti i file scelti, nell'ordine del primo file.
    /// Con pochi file si guarda anche dentro (ad esempio: niente formati audio per un video senza audio).
    private func commonTargets(_ files: [URL]) -> [String] {
        let inspect = files.count <= 10
        func targets(_ url: URL) -> [String] {
            return inspect ? FlipFormat.targets(for: url) : FlipFormat.targets(for: url.pathExtension)
        }
        var result = targets(files[0])
        for file in files.dropFirst() {
            let other = Set(targets(file))
            result = result.filter { other.contains($0) }
        }
        return result
    }

    private func names(_ urls: [URL]) -> String {
        let list = urls.prefix(5).map { $0.lastPathComponent }.joined(separator: "\n")
        return urls.count > 5 ? list + "\n…" : list
    }

    private func showAlert(title: String, text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = .warning
        alert.runModal()
    }
}
