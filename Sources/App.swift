import AppKit
import SwiftUI
import Combine
import ServiceManagement
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = UsageStore()
    private var panel: NSPanel!
    private var historyWindow: NSWindow?
    private var statusItem: NSStatusItem!
    private var cancellables = Set<AnyCancellable>()
    private let defaults = UserDefaults.standard

    private var panelVisible: Bool {
        get { defaults.object(forKey: "panelVisible") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "panelVisible") }
    }
    private var onTop: Bool {
        get { defaults.bool(forKey: "panelOnTop") }
        set { defaults.set(newValue, forKey: "panelOnTop") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `AI Usage --login-item on|off|status` (from /Applications) manages the login item
        // without going through the menu, then exits.
        if let i = CommandLine.arguments.firstIndex(of: "--login-item") {
            let arg = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : "status"
            manageLoginItem(arg)
            return
        }
        makePanel()
        makeStatusItem()
        store.$services.combineLatest(store.$now)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusTitle() }
            .store(in: &cancellables)
        store.start()
        if panelVisible { panel.orderFrontRegardless() }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            snapshot(to: CommandLine.arguments[i + 1])
        }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot-history"), i + 1 < CommandLine.arguments.count {
            snapshotHistory(to: CommandLine.arguments[i + 1])
        }
    }

    private func snapshotHistory(to path: String) {
        HistoryView.snapshotMode = true
        Task { @MainActor in
            while store.lastRefresh == nil { try? await Task.sleep(for: .milliseconds(200)) }
            let view = HistoryView().environmentObject(store).frame(width: 640, height: 640).background(Color(nsColor: .windowBackgroundColor))
            let r = ImageRenderer(content: view)
            r.scale = 2
            if let cg = r.cgImage {
                try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
    }

    /// Debug aid: `"AI Usage" --snapshot out.png` renders the panel to a PNG and quits.
    private func snapshot(to path: String) {
        PanelView.snapshotMode = true
        Task { @MainActor in
            while store.lastRefresh == nil { try? await Task.sleep(for: .milliseconds(200)) }
            let view = PanelView().environmentObject(store)
                .background(LinearGradient(colors: [Color(red: 0.15, green: 0.2, blue: 0.35), Color(red: 0.45, green: 0.2, blue: 0.3)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing))
                .environment(\.colorScheme, .dark)
            let r = ImageRenderer(content: view)
            r.scale = 2
            if let cg = r.cgImage {
                let rep = NSBitmapImageRep(cgImage: cg)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            }
            NSApp.terminate(nil)
        }
    }

    private func manageLoginItem(_ command: String) {
        let service = SMAppService.mainApp
        do {
            switch command {
            case "on": try service.register()
            case "off": try service.unregister()
            default: break
            }
        } catch {
            print("error: \(error.localizedDescription)")
            exit(1)
        }
        let state: String
        switch service.status {
        case .enabled: state = "enabled"
        case .notRegistered: state = "not registered"
        case .requiresApproval: state = "requires approval in System Settings › General › Login Items"
        case .notFound: state = "not found"
        @unknown default: state = "unknown"
        }
        print("login item: \(state)")
        exit(0)
    }

    // MARK: - Desktop panel

    private func makePanel() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 500),
                        styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        panel.appearance = NSAppearance(named: .darkAqua)
        applyLevel()

        let host = NSHostingController(rootView: PanelView().environmentObject(store))
        host.sizingOptions = [.preferredContentSize]
        panel.contentViewController = host

        // Restore position (top-left anchored so growth goes downward).
        if let s = defaults.string(forKey: "panelTopLeft") {
            panel.setFrameTopLeftPoint(NSPointFromString(s))
        } else {
            moveToDefaultPosition()
        }
        clampToScreen()

        // Persist position; keep the top edge fixed when the content height changes.
        var lastTop = panel.frame.maxY
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { note in
            guard let p = note.object as? NSPanel else { return }
            lastTop = p.frame.maxY
            UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: p.frame.minX, y: p.frame.maxY)), forKey: "panelTopLeft")
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { note in
            guard let p = note.object as? NSPanel else { return }
            if abs(p.frame.maxY - lastTop) > 0.5 {
                p.setFrameTopLeftPoint(NSPoint(x: p.frame.minX, y: lastTop))
            }
            lastTop = p.frame.maxY
        }
    }

    private func moveToDefaultPosition() {
        guard let screen = NSScreen.screens.first else { return }
        let v = screen.visibleFrame
        // The hosting view may not have laid out yet, so use the known width rather than the frame.
        panel.setFrameTopLeftPoint(NSPoint(x: v.maxX - PanelView.totalWidth - 4, y: v.maxY - 4))
    }

    /// If the saved position is off every screen (stale value, unplugged monitor), pull it back.
    private func clampToScreen() {
        let f = panel.frame
        if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(f.insetBy(dx: 40, dy: 40)) }) { return }
        moveToDefaultPosition()
    }

    private func applyLevel() {
        if let raw = ProcessInfo.processInfo.environment["AIUSAGE_LEVEL"], let v = Int(raw) {
            panel.level = NSWindow.Level(rawValue: v)   // debug override
        } else if onTop {
            panel.level = .floating
        } else {
            // Just above the wallpaper, below desktop icons — like a classic desktop widget.
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
        }
    }

    // MARK: - Menu bar

    private func makeStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "ai-usage"
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: "AI usage")
            b.imagePosition = .imageLeading
            b.title = " …"
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateStatusTitle() }
        }
    }

    private func updateStatusTitle() {
        guard let b = statusItem?.button else { return }
        guard !store.services.isEmpty else {
            b.image = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: "AI usage")
            b.image?.isTemplate = true
            b.imagePosition = .imageLeading
            b.title = " …"
            b.toolTip = "AI usage"
            return
        }
        // Drawn as a real image: the menu bar's vibrancy repaints plain title text
        // in the label color and would wipe the pace colors.
        let dark = b.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) != .aqua
        let segments = store.services.map { statusSegment(for: $0) }
        let image = statusImage(segments: segments, dark: dark)
        image.isTemplate = false
        b.title = ""
        b.imagePosition = .imageOnly
        b.image = image
        b.image?.isTemplate = false
        b.toolTip = segments.map(\.tip).joined(separator: "\n")
        b.setAccessibilityLabel(segments.map(\.tip).joined(separator: ", "))
    }

    private struct StatusSegment {
        let text: String
        let pace: Pace
        let tip: String
    }

    private func statusSegment(for s: ServiceUsage) -> StatusSegment {
        let adv = advice(for: s, at: store.now)
        let gap = paceGap(for: s, at: store.now)
        let percent: String
        if adv.pace == .locked { percent = "🔒" }
        else if s.error != nil && s.windows.isEmpty { percent = "?" }
        else { percent = Fmt.percent(s.budgetWindow?.percent ?? 0) }

        var text = percent
        var tip = "\(s.name) \(percent)"
        if let gap, adv.pace != .locked {
            if let mark = Fmt.paceMark(gap.interval) { text += " \(mark)" }
            tip += ", \(Fmt.paceDelta(gap.interval))"
        }
        if adv.pace == .locked || adv.pace == .throttled || s.error != nil {
            tip += " — \(adv.text)"
        }
        // Lock and throttle win the color so a nearly-spent short window still reads as a warning.
        let pace: Pace = (adv.pace == .locked || adv.pace == .throttled) ? adv.pace : (gap?.pace ?? adv.pace)
        return StatusSegment(text: text, pace: pace, tip: tip)
    }

    /// Gauge plus one colored chunk per subscription. The bar says "2d over"; the menu has the exact gap.
    private func statusImage(segments: [StatusSegment], dark: Bool) -> NSImage {
        let barFont = NSFont.menuBarFont(ofSize: 0)
        let font = NSFont.monospacedDigitSystemFont(ofSize: barFont.pointSize, weight: .medium)
        let symbolConfig = NSImage.SymbolConfiguration(pointSize: barFont.pointSize, weight: .medium)
        let symbol = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: "AI usage")?
            .withSymbolConfiguration(symbolConfig)

        let measure = NSMutableAttributedString()
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        for (i, seg) in segments.enumerated() {
            if i > 0 { measure.append(NSAttributedString(string: " · ", attributes: attrs)) }
            measure.append(NSAttributedString(string: seg.text, attributes: attrs))
        }
        let textSize = measure.size()
        let symbolSize = symbol?.size ?? .zero
        let spacing: CGFloat = symbolSize.width > 0 ? 4 : 0
        let size = NSSize(
            width: ceil(symbolSize.width + spacing + textSize.width),
            height: ceil(max(symbolSize.height, textSize.height, 16))
        )

        var symbolColor = dark ? NSColor.white : NSColor.black
        var separator = symbolColor.withAlphaComponent(0.4)
        if let appearance = statusItem?.button?.effectiveAppearance {
            appearance.performAsCurrentDrawingAppearance {
                symbolColor = NSColor.labelColor.usingColorSpace(.sRGB) ?? symbolColor
                separator = NSColor.labelColor.withAlphaComponent(0.4).usingColorSpace(.sRGB) ?? separator
            }
        }

        let built = NSMutableAttributedString()
        for (i, seg) in segments.enumerated() {
            if i > 0 {
                built.append(NSAttributedString(string: " · ", attributes: [
                    .font: font,
                    .foregroundColor: separator,
                ]))
            }
            built.append(NSAttributedString(string: seg.text, attributes: [
                .font: font,
                .foregroundColor: seg.pace.menuBarColor(dark: dark),
            ]))
        }

        let image = NSImage(size: size, flipped: false) { rect in
            if let symbol, symbolSize.width > 0 {
                let symbolRect = NSRect(
                    x: rect.minX,
                    y: rect.minY + (rect.height - symbolSize.height) / 2,
                    width: symbolSize.width,
                    height: symbolSize.height
                )
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: symbolRect).setClip()
                let glyph = symbol.copy() as? NSImage ?? symbol
                glyph.isTemplate = false
                glyph.draw(in: symbolRect, from: .zero, operation: .sourceOver, fraction: 1)
                symbolColor.set()
                symbolRect.fill(using: .sourceAtop)
                NSGraphicsContext.restoreGraphicsState()
            }
            built.draw(in: NSRect(
                x: rect.minX + symbolSize.width + spacing,
                y: rect.minY + (rect.height - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            ))
            return true
        }
        image.isTemplate = false
        return image
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let menuDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) != .aqua
        for s in store.services {
            let adv = advice(for: s, at: store.now)
            let name = s.name + (s.plan.map { " (\($0))" } ?? "")
            let title = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            title.isEnabled = false
            let head = NSMutableAttributedString(string: name, attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
            ])
            if let gap = paceGap(for: s, at: store.now) {
                head.append(NSAttributedString(string: "    \(Fmt.paceDelta(gap.interval))", attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: gap.pace.menuBarColor(dark: menuDark),
                ]))
            }
            title.attributedTitle = head
            menu.addItem(title)
            for w in s.windows {
                let line = "   \(w.label): \(Fmt.percent(w.percent)) used · resets in \(Fmt.duration(w.remaining(at: store.now)))"
                let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
            let a = NSMenuItem(title: "   " + adv.text, action: nil, keyEquivalent: "")
            a.isEnabled = false
            a.attributedTitle = NSAttributedString(string: a.title, attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: adv.pace.menuBarColor(dark: menuDark),
            ])
            menu.addItem(a)
            menu.addItem(.separator())
        }
        if let best = bestBet(store.services, at: store.now) {
            let b = NSMenuItem(title: "✨ Best bet right now: \(best.name)", action: nil, keyEquivalent: "")
            b.isEnabled = false
            menu.addItem(b)
            menu.addItem(.separator())
        }

        menu.addItem(withTitle: "Refresh now", action: #selector(refreshNow), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Usage history…", action: #selector(showHistory), keyEquivalent: "h").target = self
        menu.addItem(withTitle: "Export history as CSV…", action: #selector(exportCSV), keyEquivalent: "").target = self
        menu.addItem(.separator())

        let show = NSMenuItem(title: "Show desktop panel", action: #selector(togglePanel), keyEquivalent: "")
        show.state = panel.isVisible ? .on : .off
        show.target = self
        menu.addItem(show)

        let top = NSMenuItem(title: "Keep panel on top of windows", action: #selector(toggleOnTop), keyEquivalent: "")
        top.state = onTop ? .on : .off
        top.target = self
        menu.addItem(top)

        let reset = NSMenuItem(title: "Reset panel position", action: #selector(resetPosition), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)

        let login = NSMenuItem(title: "Launch at login", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        login.target = self
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit AI Usage", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func refreshNow() { Task { await store.refresh() } }

    @objc private func showHistory() {
        if historyWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 640),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "AI Usage — History"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: HistoryView().environmentObject(store))
            w.center()
            historyWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        historyWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ai-usage-history.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url, self != nil else { return }
            do { try History.shared.exportCSV(to: url) } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    @objc private func togglePanel() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
        panelVisible = panel.isVisible
    }

    @objc private func toggleOnTop() {
        onTop.toggle()
        applyLevel()
        if panel.isVisible { panel.orderFrontRegardless() }
    }

    @objc private func resetPosition() {
        defaults.removeObject(forKey: "panelTopLeft")
        moveToDefaultPosition()
        panel.orderFrontRegardless()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change login item"
            alert.informativeText = "\(error.localizedDescription)\n\nYou can add the app manually under System Settings → General → Login Items."
            alert.runModal()
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu(menu) }
}
