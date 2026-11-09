import AppKit

/// Punto di avvio dell'app FlipMac (icona nella barra dei menu, nessuna icona nel Dock).
@main
struct FlipAppMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
