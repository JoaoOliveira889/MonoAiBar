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

    private enum Timing {
        /// A click that dismissed the popover must not be read as a request to open it again.
        static let reopenSuppression: CFTimeInterval = 0.25
        /// Activation is asynchronous, so a resign notification arriving right after `show` is noise.
        static let activationSettle: CFTimeInterval = 0.4
        /// The first layout after presenting sizes the panel outright rather than animating into it.
        static let resizeSettle: CFTimeInterval = 0.3
    }

    private(set) var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var globalEventMonitor: Any?
    private var localEventMonitor: Any?
    private var resignActiveObserver: (any NSObjectProtocol)?
    private var lastHandledEventNumber: Int?
    private var lastCloseTime: CFTimeInterval = 0
    private var lastOpenTime: CFTimeInterval = 0
    private var isResizing = false

    private override init() {
        super.init()
    }

    var isPopoverOpen: Bool { popover?.isShown ?? false }

    func setup() {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            button.imagePosition = .imageOnly
        }
        statusItem = item
        updateImage()
        setupPopover()
    }

    private func setupPopover() {
        let p = NSPopover()
        p.behavior = .applicationDefined
        // Instant present/dismiss: the close animation used to leave the popover reporting
        // `isShown == true` while a new click was already asking for it to open again.
        p.animates = false
        p.delegate = self

        let hosting = PopoverHostingController(rootView: PopoverContentView())
        hosting.statusItemController = self
        // Automatic sizing snaps the window the instant the content changes. The content reports
        // the height it wants instead, and `resizePopover(toContentHeight:)` animates to it.
        hosting.sizingOptions = []
        p.contentViewController = hosting
        p.contentSize = NSSize(width: PopoverContentView.width, height: 420.0)
        self.popover = p
    }

    func popoverDidClose(_ notification: Notification) {
        lastCloseTime = CACurrentMediaTime()
        stopMonitoring()
    }

    @objc func statusItemClicked() {
        let event = NSApp.currentEvent

        // AppKit can deliver the same physical click twice while the accessory app is being
        // activated. The event number identifies the click, so the repeat is dropped.
        if let number = event?.eventNumber, number != 0 {
            guard number != lastHandledEventNumber else { return }
            lastHandledEventNumber = number
        }

        let isSecondary = event?.type == .rightMouseDown
            || event?.modifierFlags.contains(.control) == true
        if isSecondary {
            showContextMenu()
            return
        }

        togglePopover()
    }

    func togglePopover() {
        if isPopoverOpen {
            closePopover()
            return
        }
        guard CACurrentMediaTime() - lastCloseTime > Timing.reopenSuppression else { return }
        showPopover()
    }

    func showPopover() {
        guard let button = statusItem?.button else { return }

        if popover == nil {
            setupPopover()
        }

        guard let popover, !popover.isShown else { return }

        // Activate before presenting so the activation handshake cannot fire a resign
        // notification after the dismissal monitors are installed.
        NSApp.activate()

        // Present at the size the content already wants, so the first frame is not a resize.
        let fitting = popover.contentViewController?.view.fittingSize ?? .zero
        if fitting.height > 0 {
            popover.contentSize = NSSize(width: PopoverContentView.width, height: fitting.height)
        }
        lastOpenTime = CACurrentMediaTime()

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        adjustPopoverFrame()
        popover.contentViewController?.view.window?.makeKey()

        startMonitoring()

        Task { await QuotaManager.shared.refreshAllIfStale() }
    }

    private func showContextMenu() {
        guard let button = statusItem?.button else { return }
        closePopover()

        let menu = NSMenu()

        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let open = NSMenuItem(title: "Open Panel", action: #selector(openPanel), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit MonoAiBar", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY - 4), in: button)
    }

    @objc private func refreshNow() {
        Task { await QuotaManager.shared.refreshAll() }
    }

    @objc private func openPanel() {
        showPopover()
    }

    @objc private func quit() {
        closePopover()
        NSApplication.shared.terminate(nil)
    }

    func adjustPopoverFrame() {
        // Repositioning mid-resize would fight the animation with an un-animated setFrame.
        guard !isResizing else { return }
        guard let popover, popover.isShown,
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

    /// Grows or shrinks the popover to the height its content asked for. The first size is applied
    /// outright; every later change animates, which is what makes switching tabs read as one motion
    /// instead of a jump.
    func resizePopover(toContentHeight height: CGFloat) {
        guard let popover, height > 0 else { return }

        let target = NSSize(width: PopoverContentView.width, height: height.rounded())
        guard abs(popover.contentSize.height - target.height) > 0.5 else { return }

        // A size reported while the popover is opening is the initial layout, not a transition.
        let isSettlingAfterOpen = CACurrentMediaTime() - lastOpenTime < Timing.resizeSettle
        guard popover.isShown, !isResizing, !isSettlingAfterOpen else {
            popover.contentSize = target
            return
        }

        isResizing = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            popover.contentSize = target
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.isResizing = false
                self?.adjustPopoverFrame()
            }
        }
    }

    private func buttonScreenFrame() -> NSRect? {
        guard let button = statusItem?.button, let window = button.window else { return nil }
        let frameInWindow = button.convert(button.bounds, to: nil)
        return window.convertToScreen(frameInWindow)
    }

    private func startMonitoring() {
        stopMonitoring()

        // Global monitor: detect clicks in other applications or the desktop.
        // The hit test runs synchronously, while the pointer is still where the click landed.
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            let clickLocation = NSEvent.mouseLocation
            Task { @MainActor [weak self] in
                guard let self, self.isPopoverOpen else { return }

                // A click on the status item itself belongs to the button action, which toggles
                // the popover closed on its own.
                if let buttonFrame = self.buttonScreenFrame(), buttonFrame.contains(clickLocation) {
                    return
                }

                self.closePopover()
            }
        }

        // Local monitor: catch Escape, let every other in-app event through untouched.
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard event.keyCode == 53 /* Escape */ else { return event }
            MainActor.assumeIsolated {
                self?.closePopover()
            }
            return nil
        }

        // Deactivation observer: close popover if active application changes (e.g. Cmd+Tab)
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPopoverOpen else { return }
                guard CACurrentMediaTime() - self.lastOpenTime > Timing.activationSettle else { return }
                self.closePopover()
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
        let threshold = settings.warningThreshold
        let image = MenuBarRenderer.shared.image(
            mode: settings.displayMode,
            providers: settings.enabledProviders,
            usage: settings.enabledProviders.map { quota.usageText(for: $0) },
            alerts: settings.enabledProviders.map { provider in
                let status = quota.status(for: provider)
                return status.state.isError || status.peakUsagePercent >= threshold
            }
        )
        button.image = image
    }

    func closePopover() {
        guard let popover, popover.isShown else {
            stopMonitoring()
            return
        }
        stopMonitoring()
        lastCloseTime = CACurrentMediaTime()
        popover.close()
    }
}
