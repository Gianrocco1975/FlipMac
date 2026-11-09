import AppKit
import ServiceManagement

/// Icona nella barra dei menu, menu, "Apri con" dal Finder, trascinamento sull'icona, gesto ↓,
/// avvio al login e aggiornamenti da GitHub.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let wheel: WheelController
    private let dropTarget: StatusDropTarget
    private let gesture: DragGesture
    private var gestureItem: NSMenuItem?
    private var loginItem: NSMenuItem?
    private var updateItem: NSMenuItem?
    private var gestureEnabled: Bool
    private var waitingForPermission = false
    private var pendingUpdateCommits = 0
    private var updating = false

    private static let gestureEnabledKey = "gestureEnabled"
    private static let askedPermissionKey = "askedAccessibilityPermission"
    private static let lastUpdateCheckKey = "lastUpdateCheck"

    override init() {
        wheel = WheelController()
        dropTarget = StatusDropTarget()
        gesture = DragGesture()
        gestureEnabled = UserDefaults.standard.object(forKey: Self.gestureEnabledKey) as? Bool ?? true
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "FlipMac")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "FlipMac — trascina qui i file da convertire, oppure premi ↓ mentre li trascini"
        }
        item.menu = buildMenu()
        statusItem = item

        let wheel = self.wheel
        dropTarget.onDrop = { urls in
            wheel.show(files: urls)
        }
        registerDrop()

        gesture.onTrigger = { urls in
            Task { @MainActor in wheel.showForDrag(files: urls) }
        }
        gesture.onMouseUp = {
            Task { @MainActor in wheel.dragEnded() }
        }
        gesture.onEscape = {
            Task { @MainActor in wheel.dragCancelled() }
        }
        setUpGesture()
        updateLoginMenu()
        updateUpdateMenu()
        scheduleAutomaticUpdateCheck()

        let build = BuildInfo.current
        FlipLog.write("FlipMac \(build.version) avviato\(build.shortCommit.map { " (commit \($0))" } ?? "")")
    }

    /// File aperti con "Apri con → FlipMac" dal Finder (o trascinati sull'app).
    func application(_ application: NSApplication, open urls: [URL]) {
        wheel.show(files: urls)
    }

    // MARK: - Gesto ↓ durante il trascinamento

    private func setUpGesture() {
        defer { updateGestureMenu() }
        guard gestureEnabled else { return }

        if DragGesture.isTrusted {
            if gesture.start() {
                FlipLog.write("Gesto ↓ attivo")
            } else {
                FlipLog.write("Gesto ↓: macOS non ha concesso l'event tap")
            }
            return
        }

        // Permesso Accessibilità mancante: la richiesta di macOS compare da sola solo al primo avvio,
        // poi si usa la voce del menu.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: Self.askedPermissionKey) {
            defaults.set(true, forKey: Self.askedPermissionKey)
            DragGesture.requestPermission()
        }
        waitForPermission()
    }

    /// Controlla ogni due secondi se il permesso è arrivato, e allora attiva il gesto.
    private func waitForPermission() {
        guard !waitingForPermission else { return }
        waitingForPermission = true
        Task { @MainActor in
            while !DragGesture.isTrusted {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            self.waitingForPermission = false
            if self.gestureEnabled && self.gesture.start() {
                FlipLog.write("Permesso Accessibilità concesso: gesto ↓ attivo")
            }
            self.updateGestureMenu()
        }
    }

    private func updateGestureMenu() {
        guard let item = gestureItem else { return }
        if !gestureEnabled {
            item.title = "Gesto ↓ durante il trascinamento"
            item.state = .off
        } else if gesture.isRunning {
            item.title = "Gesto ↓ durante il trascinamento"
            item.state = .on
        } else {
            item.title = "Gesto ↓: concedi il permesso Accessibilità…"
            item.state = .off
        }
    }

    @objc private func toggleGesture(_ sender: Any?) {
        if gestureEnabled && !gesture.isRunning {
            // Attivo ma senza permesso: si porta l'utente alle Impostazioni.
            DragGesture.requestPermission()
            openSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            waitForPermission()
            return
        }
        gestureEnabled.toggle()
        UserDefaults.standard.set(gestureEnabled, forKey: Self.gestureEnabledKey)
        if gestureEnabled {
            setUpGesture()
        } else {
            gesture.stop()
            FlipLog.write("Gesto ↓ disattivato")
            updateGestureMenu()
        }
    }

    // MARK: - Avvio al login

    private func updateLoginMenu() {
        guard let item = loginItem else { return }
        switch SMAppService.mainApp.status {
        case .enabled:
            item.title = "Apri al login"
            item.state = .on
        case .requiresApproval:
            item.title = "Apri al login: da approvare nelle Impostazioni…"
            item.state = .mixed
        default:
            item.title = "Apri al login"
            item.state = .off
        }
    }

    @objc private func toggleLogin(_ sender: Any?) {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled:
                try service.unregister()
                FlipLog.write("Avvio al login disattivato")
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            default:
                try service.register()
                FlipLog.write("Avvio al login attivato (\(Bundle.main.bundlePath))")
            }
        } catch {
            FlipLog.write("Avvio al login: \(error.localizedDescription)")
            showAlert(title: "Impossibile cambiare l'avvio al login", text: error.localizedDescription)
        }
        if service.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        updateLoginMenu()
    }

    // MARK: - Aggiornamenti

    private func updateUpdateMenu() {
        guard let item = updateItem else { return }
        if updating {
            item.title = "Aggiornamento in corso…"
            item.isEnabled = false
        } else if pendingUpdateCommits > 0 {
            let plural = pendingUpdateCommits == 1 ? "modifica" : "modifiche"
            item.title = "⬆︎ Aggiornamento disponibile (\(pendingUpdateCommits) \(plural))…"
            item.isEnabled = true
        } else {
            item.title = "Controlla aggiornamenti…"
            item.isEnabled = true
        }
    }

    /// Un controllo silenzioso al giorno, poco dopo l'avvio.
    private func scheduleAutomaticUpdateCheck() {
        guard BuildInfo.current.canUpdate else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastUpdateCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 24 * 3600 else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            self.runUpdateCheck(interactive: false)
        }
    }

    @objc private func checkForUpdates(_ sender: Any?) {
        if pendingUpdateCommits > 0 {
            offerUpdate(newCommits: pendingUpdateCommits)
        } else {
            runUpdateCheck(interactive: true)
        }
    }

    private func runUpdateCheck(interactive: Bool) {
        let build = BuildInfo.current
        guard build.canUpdate else {
            if interactive {
                showAlert(title: "Aggiornamenti non ancora attivi",
                          text: "FlipMac controlla gli aggiornamenti sulla tua repo GitHub, ma questa copia non è stata compilata da una repo git.\n\nPubblica la cartella del progetto su GitHub (vedi README, «Aggiornamenti») e ricompila l'app con ./scripts/build-app.sh --install.")
            }
            return
        }
        guard !updating, let item = updateItem else { return }
        item.title = "Controllo aggiornamenti…"
        item.isEnabled = false

        DispatchQueue.global(qos: .utility).async {
            let result = Updater.check(build)
            Task { @MainActor in
                self.handleUpdateResult(result, interactive: interactive)
            }
        }
    }

    private func handleUpdateResult(_ result: UpdateResult, interactive: Bool) {
        UserDefaults.standard.set(Date(), forKey: Self.lastUpdateCheckKey)
        switch result {
        case .upToDate:
            pendingUpdateCommits = 0
            updateUpdateMenu()
            if interactive {
                let build = BuildInfo.current
                showAlert(title: "FlipMac è aggiornato",
                          text: "Versione \(build.version)\(build.shortCommit.map { " (commit \($0))" } ?? ""): su GitHub non ci sono modifiche nuove.",
                          style: .informational)
            }
        case .available(let count):
            pendingUpdateCommits = count
            updateUpdateMenu()
            FlipLog.write("Aggiornamento disponibile: \(count) modifiche su GitHub")
            if interactive {
                offerUpdate(newCommits: count)
            }
        case .notConfigured:
            pendingUpdateCommits = 0
            updateUpdateMenu()
        case .failed(let reason):
            updateUpdateMenu()
            FlipLog.write("Controllo aggiornamenti non riuscito: \(reason)")
            if interactive {
                showAlert(title: "Controllo aggiornamenti non riuscito", text: reason)
            }
        }
    }

    private func offerUpdate(newCommits: Int) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "È disponibile un aggiornamento di FlipMac"
        alert.informativeText = "Su GitHub ci sono \(newCommits) \(newCommits == 1 ? "modifica nuova" : "modifiche nuove").\n\nFlipMac le scarica, si ricompila, si reinstalla e si riavvia: serve un paio di minuti."
        alert.addButton(withTitle: "Aggiorna ora")
        alert.addButton(withTitle: "Più tardi")
        if alert.runModal() == .alertFirstButtonReturn {
            performUpdate()
        }
    }

    private func performUpdate() {
        let build = BuildInfo.current
        let installedPath = NSHomeDirectory() + "/Applications/FlipMac.app"
        let isInstalled = Bundle.main.bundlePath == installedPath
        let relaunchPath = isInstalled ? installedPath : Bundle.main.bundlePath

        updating = true
        updateUpdateMenu()
        FlipLog.write("Aggiornamento in corso (registro: \(Updater.logURL.path))")

        DispatchQueue.global(qos: .userInitiated).async {
            let success = Updater.install(build, intoApplications: isInstalled)
            Task { @MainActor in
                self.finishUpdate(success: success, relaunchPath: relaunchPath)
            }
        }
    }

    private func finishUpdate(success: Bool, relaunchPath: String) {
        updating = false
        guard success else {
            updateUpdateMenu()
            FlipLog.write("Aggiornamento non riuscito")
            showAlert(title: "Aggiornamento non riuscito",
                      text: "I dettagli sono nel registro dell'aggiornamento, che si apre adesso.")
            NSWorkspace.shared.open(Updater.logURL)
            return
        }

        FlipLog.write("Aggiornamento completato: riavvio")
        // La nuova versione si apre un secondo dopo la chiusura di questa.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"$1\"", "sh", relaunchPath]
        try? relaunch.run()
        gesture.stop()
        NSApp.terminate(nil)
    }

    // MARK: - Trascinamento sull'icona

    /// La finestra dell'icona inoltra il trascinamento al suo delegato (StatusDropTarget).
    private func registerDrop() {
        if let window = statusItem?.button?.window {
            window.registerForDraggedTypes([.fileURL])
            window.delegate = dropTarget
            return
        }
        // La finestra dell'icona a volte nasce un attimo dopo: si riprova.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            if let window = self.statusItem?.button?.window {
                window.registerForDraggedTypes([.fileURL])
                window.delegate = self.dropTarget
            } else {
                FlipLog.write("Impossibile attivare il trascinamento sull'icona")
            }
        }
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let convert = NSMenuItem(title: "Converti file…", action: #selector(openFiles(_:)), keyEquivalent: "o")
        convert.target = self
        menu.addItem(convert)

        let hint = NSMenuItem(title: "Oppure trascina i file sull'icona, o premi ↓ mentre li trascini", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        menu.addItem(.separator())

        let gestureItem = NSMenuItem(title: "Gesto ↓ durante il trascinamento", action: #selector(toggleGesture(_:)), keyEquivalent: "")
        gestureItem.target = self
        menu.addItem(gestureItem)
        self.gestureItem = gestureItem

        let loginItem = NSMenuItem(title: "Apri al login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)
        self.loginItem = loginItem

        menu.addItem(.separator())

        let updateItem = NSMenuItem(title: "Controlla aggiornamenti…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)
        self.updateItem = updateItem

        let log = NSMenuItem(title: "Apri registro", action: #selector(openLog(_:)), keyEquivalent: "")
        log.target = self
        menu.addItem(log)

        let about = NSMenuItem(title: "Informazioni su FlipMac", action: #selector(showAbout(_:)), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Esci da FlipMac", action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    @objc private func openFiles(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = "Scegli i file da convertire"
        panel.prompt = "Scegli"
        if panel.runModal() == .OK {
            wheel.show(files: panel.urls)
        }
    }

    @objc private func openLog(_ sender: Any?) {
        FlipLog.write("Registro aperto dal menu")
        NSWorkspace.shared.open(FlipLog.url)
    }

    @objc private func showAbout(_ sender: Any?) {
        let build = BuildInfo.current
        var lines = ["Convertitore di file locale per macOS, ispirato a FLIP.",
                     "Trascina un file e premi ↓, oppure trascinalo sull'icona."]
        if let commit = build.shortCommit {
            lines.append("Compilato dal commit \(commit)\(build.branch.map { " (\($0))" } ?? "").")
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let credits = NSAttributedString(string: lines.joined(separator: "\n"), attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph
        ])
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc private func quit(_ sender: Any?) {
        gesture.stop()
        NSApp.terminate(nil)
    }

    // MARK: - Utilità

    private func openSettings(_ address: String) {
        if let url = URL(string: address) {
            NSWorkspace.shared.open(url)
        }
    }

    private func showAlert(title: String, text: String, style: NSAlert.Style = .warning) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.alertStyle = style
        alert.runModal()
    }
}

/// Riceve i file trascinati sull'icona della barra dei menu.
@MainActor
final class StatusDropTarget: NSObject, NSWindowDelegate, NSDraggingDestination {
    var onDrop: (([URL]) -> Void)?

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return fileURLs(from: sender).isEmpty ? [] : .copy
    }

    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return fileURLs(from: sender).isEmpty ? [] : .copy
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }

    private func fileURLs(from info: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objects = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) ?? []
        return objects.compactMap { $0 as? URL }.filter { !$0.hasDirectoryPath }
    }
}
