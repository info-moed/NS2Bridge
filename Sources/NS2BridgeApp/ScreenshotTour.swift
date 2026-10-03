import AppKit
import NS2Kit
import SceneKit

/// Developer aid for the documentation: `NS2Bridge --screenshot-tour <folder>` opens the app with Demo mode on and
/// a clean state, visits every tab in light and dark mode, saves each as `tab-<name>-<light|dark>.png`, then quits.
/// The window draws itself (`cacheDisplay`), so no Screen Recording permission is needed.
@MainActor
enum ScreenshotTour {
    /// Set from the command line before the model exists.
    static var folder: URL?

    /// Personal state never appears in a screenshot: these read-only overrides (the argument domain, which isn't
    /// saved) hide the game list, analyses and profiles, and show every tab.
    static func prepareDefaults() {
        UserDefaults.standard.setVolatileDomain([
            "games": [String](), "games.verified": [String](), "games.analysis": Data(), "profiles": Data(),
            "ui.advanced": true, "motion.mode": "on", "bluetooth.speed": "fastest",
            "welcome.install": BridgeModel.installationID,
        ], forName: UserDefaults.argumentDomain)
    }

    static func run(model: BridgeModel) async {
        guard let folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        model.showWelcome = false
        model.demoMode = true
        try? await Task.sleep(for: .seconds(2))
        guard let window = NSApp.windows.first(where: { $0.title == "NS2 Bridge" }) else { exit(1) }
        window.setContentSize(NSSize(width: 1080, height: 720))
        window.center()
        model.runLatencyTest()                                  // 10 s: done before the Latency tab is shown
        for (name, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            NSApp.appearance = NSAppearance(named: name)
            for pane in Pane.allCases {
                if pane == .latency, model.latencyResult == nil { try? await Task.sleep(for: .seconds(10)) }
                model.requestedPane = pane
                try? await Task.sleep(for: .seconds(1.5))
                save(window, to: folder.appendingPathComponent("tab-\(slug(pane))-\(suffix).png"))
            }
            // The diagnostics report sheet (also checks the report builds on a real system).
            model.requestedPane = .diagnostics
            model.showDiagnosticsReport()
            try? await Task.sleep(for: .seconds(1.5))
            if let sheet = window.attachedSheet { save(sheet, to: folder.appendingPathComponent("diagnostics-report-\(suffix).png")) }
            try? model.diagnosticsReport?.write(to: folder.appendingPathComponent("diagnostics-report.md"), atomically: true, encoding: .utf8)
            model.diagnosticsReport = nil
            try? await Task.sleep(for: .seconds(0.8))
        }
        exit(0)
    }

    static func slug(_ pane: Pane) -> String {
        pane.rawValue.lowercased().replacingOccurrences(of: " & ", with: "-").replacingOccurrences(of: " ", with: "-")
    }

    private static func save(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        // cacheDisplay skips Metal content: draw each 3D view's own snapshot in its place.
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            for scene in sceneViews(in: view) {
                let frame = scene.convert(scene.bounds, to: view)
                let rect = view.isFlipped ? NSRect(x: frame.minX, y: view.bounds.height - frame.maxY, width: frame.width, height: frame.height) : frame
                scene.snapshot().draw(in: rect)
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func sceneViews(in view: NSView) -> [SCNView] {
        (view as? SCNView).map { [$0] } ?? view.subviews.flatMap(sceneViews(in:))
    }
}
