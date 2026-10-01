import AppKit
import NS2Kit
import SwiftUI

/// The controllers in the menu bar: one item showing a pill per controller in its player's color
/// (GC blue = P1, N64 red = P2…). Click a pill for that controller's menu; double-click it to turn the
/// controller off (with a confirmation). While controllers are shown here, the plain NS2 Bridge icon is
/// hidden and its commands live in this menu, so NS2 Bridge takes a single spot in the menu bar.
///
/// One item (not one per controller) so nothing is added, removed or reordered when controllers change:
/// the image is updated in place, and macOS remembers where the user ⌘-drags it (autosave name).
@MainActor
final class ControllerStatusItems: NSObject {
    private weak var model: BridgeModel?
    private var item: NSStatusItem?
    private var shown: [ControllerSummary] = []
    private var pillRanges: [(id: String, range: ClosedRange<CGFloat>)] = []
    private var signature = ""
    private var pendingClick: DispatchWorkItem?
    /// Short, so a single click feels immediate; a double-click must land within it.
    private let doubleClickWindow = min(NSEvent.doubleClickInterval, 0.25)

    init(model: BridgeModel) {
        self.model = model
        super.init()
    }

    /// Called whenever the controller list changes (about once a second). Cheap when nothing changed.
    func update(_ controllers: [ControllerSummary]) {
        let sorted = controllers.sorted { $0.player < $1.player }
        let sig = sorted.map { "\($0.id)|\($0.player)|\($0.kind.rawValue)|\($0.ready)|\($0.transport.rawValue)" }.joined(separator: ";")
        defer { checkVisibility() }
        guard sig != signature else { return }
        signature = sig
        shown = sorted
        if sorted.isEmpty {
            if let item { NSStatusBar.system.removeStatusItem(item) }
            item = nil
            return
        }
        if item == nil {
            let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            i.autosaveName = "NS2BridgeControllers"
            i.button?.target = self
            i.button?.action = #selector(clicked(_:))
            i.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            item = i
        }
        let (image, ranges) = Self.render(sorted)
        item?.button?.image = image
        pillRanges = ranges
        item?.button?.toolTip = sorted.map { "P\($0.player) · \($0.kind.displayName)\($0.transport == .bluetooth ? " · Bluetooth" : "")" }
            .joined(separator: "\n") + "\nClick a controller for options · double-click to turn it off"
    }

    /// Is the item actually on screen? On a MacBook with a camera notch and a full menu bar, macOS
    /// hides items that don't fit (they end up behind the notch), without telling the app.
    private func checkVisibility() {
        guard let model else { return }
        var hidden = false
        if let frame = item?.button?.window?.frame, let screen = item?.button?.window?.screen ?? NSScreen.main,
           let right = screen.auxiliaryTopRightArea {
            hidden = frame.minX < right.minX + 1          // left of the notch's right edge = not visible
        }
        if model.menuBarTagsHidden != hidden { model.menuBarTagsHidden = hidden }
    }

    // MARK: Clicks

    @objc private func clicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        let x = sender.convert(event.locationInWindow, from: nil).x
        let id = pillRanges.first { $0.range.contains(x) }?.id ?? pillRanges.min { abs($0.range.lowerBound - x) < abs($1.range.lowerBound - x) }?.id
        pendingClick?.cancel()
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showMenu(for: id, from: sender)
        } else if event.clickCount >= 2 {
            if let id { model?.confirmTurnOff(id) }
        } else {
            let work = DispatchWorkItem { [weak self, weak sender] in
                guard let self, let sender else { return }
                self.showMenu(for: id, from: sender)
            }
            pendingClick = work
            DispatchQueue.main.asyncAfter(deadline: .now() + doubleClickWindow, execute: work)
        }
    }

    private func showMenu(for id: String?, from button: NSStatusBarButton) {
        guard let model else { return }
        let menu = NSMenu()
        if let id, let c = model.controllers.first(where: { $0.id == id }) {
            let title = NSMenuItem(title: "P\(c.player) · \(c.kind.displayName)", action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            let detail = NSMenuItem(title: "\(c.transport.rawValue) · \(c.ready ? "\(Int((c.battery * 100).rounded()))%\(c.charging ? " charging" : "")" : "setting up…")",
                                    action: nil, keyEquivalent: "")
            detail.isEnabled = false
            menu.addItem(detail)
            menu.addItem(MenuAction("Open \(c.kind.displayName) Settings") { model.showController(id) })
            menu.addItem(MenuAction(model.canDisconnect(id) ? "Turn Off…" : "Disconnect…") { model.confirmTurnOff(id) })
            let others = model.controllers.filter { $0.id != id }.sorted { $0.player < $1.player }
            if !others.isEmpty {
                menu.addItem(.separator())
                for o in others {
                    let sub = NSMenu()
                    sub.addItem(MenuAction("Open Settings") { model.showController(o.id) })
                    sub.addItem(MenuAction(model.canDisconnect(o.id) ? "Turn Off…" : "Disconnect…") { model.confirmTurnOff(o.id) })
                    let entry = NSMenuItem(title: "P\(o.player) · \(o.kind.displayName)", action: nil, keyEquivalent: "")
                    entry.submenu = sub
                    menu.addItem(entry)
                }
            }
        }
        menu.addItem(.separator())
        menu.addItem(MenuAction("Open NS2 Bridge…") { model.openMainWindow?(); NSApp.activate(ignoringOtherApps: true) })
        menu.addItem(MenuAction("Quit NS2 Bridge") { NSApp.terminate(nil) })
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    // MARK: Drawing

    static let pillHeight: CGFloat = 15, spacing: CGFloat = 3, font = NSFont.systemFont(ofSize: 10, weight: .heavy)

    /// All pills in one color (non-template) image, plus each pill's horizontal range for hit-testing.
    static func render(_ controllers: [ControllerSummary]) -> (NSImage, [(id: String, range: ClosedRange<CGFloat>)]) {
        let rounded = NSFont(descriptor: font.fontDescriptor.withDesign(.rounded) ?? font.fontDescriptor, size: 10) ?? font
        var widths: [CGFloat] = []
        var labels: [NSAttributedString] = []
        for c in controllers {
            let ink = NSColor(PlayerColor.ink(c.player))
            let s = NSAttributedString(string: c.kind.menuCode, attributes: [.font: rounded, .foregroundColor: ink])
            labels.append(s)
            widths.append(ceil(s.size().width) + 8)
        }
        let total = widths.reduce(0, +) + spacing * CGFloat(max(0, widths.count - 1))
        let height: CGFloat = 18
        var ranges: [(id: String, range: ClosedRange<CGFloat>)] = []
        var x: CGFloat = 0
        for (i, c) in controllers.enumerated() {
            ranges.append((c.id, x...(x + widths[i] + spacing)))
            x += widths[i] + spacing
        }
        let image = NSImage(size: NSSize(width: max(total, 1), height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for (i, c) in controllers.enumerated() {
                let rect = NSRect(x: x, y: (height - pillHeight) / 2, width: widths[i], height: pillHeight)
                NSColor(PlayerColor.of(c.player)).withAlphaComponent(c.ready ? 1 : 0.45).setFill()
                NSBezierPath(roundedRect: rect, xRadius: pillHeight / 2, yRadius: pillHeight / 2).fill()
                let size = labels[i].size()
                labels[i].draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
                x += widths[i] + spacing
            }
            return true
        }
        image.isTemplate = false
        return (image, ranges)
    }
}

/// NSMenuItem that runs a closure.
final class MenuAction: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError("not used") }
    @objc private func run() { handler() }
}
