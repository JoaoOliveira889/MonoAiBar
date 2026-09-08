import AppKit
import SwiftUI

@MainActor
final class PopoverHostingController<Content: View>: NSHostingController<Content> {
    weak var statusItemController: StatusItemController?

    override func viewDidLayout() {
        super.viewDidLayout()
        statusItemController?.adjustPopoverFrame()
    }
}

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    static let shared = StatusItemController()

    private(set) var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var isPresented = false
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    private var resignActiveObserver: (any NSObjectProtocol)?

    private override init() {
        super.init()
    }

    func setup() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseDown])
            button.imagePosition = .imageOnly
        }
        statusItem = item
        updateImage()
        setupPopover()
    }

    private func setupPopover() {
        let p = NSPopover()
        p.behavior = .applicationDefined
        p.animates = true
        p.delegate = self

        let hosting = PopoverHostingController(rootView: PopoverContentView())
        hosting.statusItemController = self
        p.contentViewController = hosting
        self.popover = p
    }

    func popoverDidClose(_ notification: Notification) {
        isPresented = false
        stopMonitoring()
    }

    @objc func statusItemClicked() {
        if isPresented {
            closePopover()
        } else {
            showPopover()
        }
    }

    func showPopover() {
        guard let button = statusItem?.button else { return }

        if popover == nil {
            setupPopover()
        }

        guard let popover else { return }

        isPresented = true

        // Proactively refresh quotas in the background when user opens the popover
        Task { await QuotaManager.shared.refreshAll() }

        // Pre-size the popover before presenting so AppKit calculates initial positioning correctly
        if let hosting = popover.contentViewController as? PopoverHostingController<PopoverContentView> {
            let fittingSize = hosting.view.fittingSize
            if fittingSize.width > 0 && fittingSize.height > 0 {
                popover.contentSize = fittingSize
            } else {
                popover.contentSize = NSSize(width: PopoverContentView.width, height: 420)
            }
        }

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        adjustPopoverFrame()

        // Bring the accessory app into active state so clicks and keyboard focus behave naturally
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()

        startMonitoring()
    }

    func adjustPopoverFrame() {
        guard let popover, isPresented,
              let popoverWindow = popover.contentViewController?.view.window,
              let button = statusItem?.button,
              let buttonWindow = button.window else { return }

        let frameInWindow = button.convert(button.bounds, to: nil)
        let buttonScreenRect = buttonWindow.convertToScreen(frameInWindow)
        let statusBarBottomY = buttonScreenRect.minY

        // Ensure popoverWindow's top edge (maxY) is at or below the status bar bottom (with 2pt spacing)
        let maxAllowedTop = statusBarBottomY - 2.0
        var popoverFrame = popoverWindow.frame

        if popoverFrame.maxY > maxAllowedTop {
            // Window expanded upwards into or above the menu bar!
            // Shift origin.y downwards so the top stays anchored right below the status bar:
            popoverFrame.origin.y = maxAllowedTop - popoverFrame.height
            popoverWindow.setFrame(popoverFrame, display: true, animate: false)
        }
    }

    private func buttonScreenFrame() -> NSRect? {
        guard let button = statusItem?.button, let window = button.window else { return nil }
        let frameInWindow = button.convert(button.bounds, to: nil)
        return window.convertToScreen(frameInWindow)
    }

    private func startMonitoring() {
        stopMonitoring()

        // Global monitor: detect clicks in other applications or the desktop
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.isPresented else { return }

                // If click is on the status item button itself, ignore it here
                // so the button's action handler can toggle it closed cleanly.
                if let buttonFrame = self.buttonScreenFrame() {
                    let mouseLoc = NSEvent.mouseLocation
                    if buttonFrame.contains(mouseLoc) {
                        return
                    }
                }

                self.closePopover()
            }
        }

        // Local monitor: catch Escape key and clicks within the app
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            if event.type == .keyDown {
                if event.keyCode == 53 /* Escape */ {
                    Task { @MainActor [weak self] in
                        self?.closePopover()
                    }
                    return nil
                }
                return event
            }

            // For mouse clicks within our app:
            // If the click is inside the popover window or on the button window, let it through normally!
            return event
        }

        // Deactivation observer: close popover if active application changes (e.g. Cmd+Tab)
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.closePopover()
            }
        }
    }

    private func stopMonitoring() {
        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
        if let observer = resignActiveObserver {
            NotificationCenter.default.removeObserver(observer)
            resignActiveObserver = nil
        }
    }

    func updateImage() {
        guard let button = statusItem?.button else { return }
        let settings = SettingsStore.shared
        let quota = QuotaManager.shared
        let image = MenuBarRenderer.shared.image(
            mode: settings.displayMode,
            providers: settings.enabledProviders,
            usage: settings.enabledProviders.map { quota.usageText(for: $0) }
        )
        button.image = image
    }

    func closePopover() {
        isPresented = false
        stopMonitoring()
        popover?.performClose(nil)
    }
}

