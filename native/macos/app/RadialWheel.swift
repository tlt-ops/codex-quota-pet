import AppKit
import os

private let wheelLogger = Logger(subsystem: "com.tanlantian.CodexQuotaPet", category: "RadialWheel")

/// The pet's double-click menu. It lives in its own window so opening the
/// wheel never changes the character or the quota bubble's drawing.
@MainActor
final class RadialWheel {
    enum Action: CaseIterable {
        case show
        case hide
        case refresh
        case rain
        case arc
        case bounce
        case autoOpen
        case quit
        case testDamage
        case testXP

        fileprivate var titleLines: [String] {
            switch self {
            case .show: return ["显示"]
            case .hide: return ["隐藏"]
            case .refresh: return ["刷新额度"]
            case .rain: return ["GPT雨"]
            case .arc: return ["抛物线"]
            case .bounce: return ["弹射"]
            case .autoOpen: return ["自动打开"]
            case .quit: return ["退出"]
            case .testDamage: return ["测试", "受击音"]
            case .testXP: return ["测试", "经验音"]
            }
        }

        /// Clockwise, with Show at twelve o'clock and Hide next to it.
        fileprivate var spokeIndex: Int {
            switch self {
            case .show: return 0
            case .refresh: return 1
            case .rain: return 2
            case .arc: return 3
            case .bounce: return 4
            case .testXP: return 5
            case .testDamage: return 6
            case .quit: return 7
            case .autoOpen: return 8
            case .hide: return 9
            }
        }

        fileprivate var direction: NSPoint {
            let angle = CGFloat.pi / 2 - CGFloat(spokeIndex) * 2 * .pi / 10
            return NSPoint(x: cos(angle), y: sin(angle))
        }
    }

    static let preferredSide: CGFloat = 420

    var onSelect: ((Action) -> Void)?
    // Treat a queued presentation as open so a second double-click can cancel
    // it before AppKit has ordered its window into the current Space.
    var isVisible: Bool { panel?.isVisible == true || pendingPresentationID != nil }

    private var panel: NSPanel?
    private var wheelView: RadialWheelView?
    private var animationTimer: Timer?
    private var animationStartedAt: TimeInterval = 0
    private var localClickMonitor: Any?
    private var shownAt: TimeInterval = 0
    private var pendingPresentationID: UUID?

    /// Keep the controls clear of the Dock and menu bar. A malformed or very
    /// small visible frame cannot hold a usable wheel, so use the full display.
    static func usableScreenFrame(screenFrame: NSRect, visibleFrame: NSRect) -> NSRect {
        let screen = screenFrame.standardized
        let visible = visibleFrame.standardized.intersection(screen)
        let minimumSide: CGFloat = 332 // 320 pt wheel plus the 6 pt edge inset.
        guard !visible.isNull,
              visible.width >= minimumSide,
              visible.height >= minimumSide else { return screen }
        return visible
    }

    /// Kept independent of `NSScreen` so placement can be checked without
    /// opening a window. The wheel unfolds over the character at the click
    /// point, or over the center of the pet when opened from a menu.
    static func placement(near petFrame: NSRect, in screenFrame: NSRect,
                          at screenPoint: NSPoint? = nil) -> NSRect {
        let screen = screenFrame.standardized
        let inset = min(CGFloat(6), max(0, (min(screen.width, screen.height) - 1) / 2))
        let side = max(1, min(preferredSide, screen.width - inset * 2,
                              screen.height - inset * 2))
        func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
            min(max(value, low), high)
        }
        let center = screenPoint ?? NSPoint(x: petFrame.midX, y: petFrame.midY)
        let xLow = screen.minX + inset
        let xHigh = screen.maxX - inset - side
        let yLow = screen.minY + inset
        let yHigh = screen.maxY - inset - side
        return NSRect(x: clamp(center.x - side / 2, xLow, xHigh),
                      y: clamp(center.y - side / 2, yLow, yHigh),
                      width: side, height: side)
    }

    static func buttonCenter(for action: Action, in bounds: NSRect,
                             progress: CGFloat = 1) -> NSPoint {
        let hub = NSPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) * 0.365 * min(max(progress, 0), 1)
        return NSPoint(x: hub.x + action.direction.x * radius,
                       y: hub.y + action.direction.y * radius)
    }

    static func buttonRadius(in bounds: NSRect) -> CGFloat {
        min(bounds.width, bounds.height) * 40 / preferredSide
    }

    static func hubRadius(in bounds: NSRect) -> CGFloat {
        min(bounds.width, bounds.height) * 34 / preferredSide
    }

    func show(near petFrame: NSRect, on screen: NSScreen, selectedMode: Action,
              at screenPoint: NSPoint? = nil, autoOpenStatus: String? = nil) {
        dismiss()
        let usableFrame = Self.usableScreenFrame(screenFrame: screen.frame,
                                                 visibleFrame: screen.visibleFrame)
        let frame = Self.placement(near: petFrame, in: usableFrame,
                                   at: screenPoint)
        let window = NSPanel(contentRect: frame,
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        // Keep controls above the click-through rain overlay if both are open.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.acceptsMouseMovedEvents = true
        let view = RadialWheelView(frame: NSRect(origin: .zero, size: frame.size))
        view.selectedMode = selectedMode
        view.autoOpenStatus = autoOpenStatus
        view.onAction = { [weak self] action in
            guard let self else { return }
            let callback = self.onSelect
            self.dismiss()
            callback?(action)
        }
        view.onDismiss = { [weak self] in self?.dismiss() }
        window.contentView = view
        panel = window
        wheelView = view
        let presentationID = UUID()
        pendingPresentationID = presentationID
        NSLog("CodexQuotaPet radial wheel queued at %@", NSStringFromRect(frame))
        wheelLogger.info("queued")

        // This can be requested from the pet's mouseUp or from a tracking
        // menu. Wait for AppKit's default run-loop mode before presenting the
        // transparent panel, then commit a visible first frame to its backing
        // store. Otherwise the compositor may reveal it only after a Space
        // switch, as happened with the rain overlay.
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            Task { @MainActor [weak self] in
                self?.present(if: presentationID)
            }
        }
    }

    private func present(if presentationID: UUID) {
        guard pendingPresentationID == presentationID,
              let window = panel, let view = wheelView else { return }
        pendingPresentationID = nil
        view.progress = 0.15
        window.display()
        window.orderFrontRegardless()
        window.displayIfNeeded()
        animationStartedAt = ProcessInfo.processInfo.systemUptime
        shownAt = animationStartedAt
        NSLog("CodexQuotaPet radial wheel presented at %@", NSStringFromRect(window.frame))
        wheelLogger.info("presented visible=\(window.isVisible, privacy: .public) occluded=\(!window.occlusionState.contains(.visible), privacy: .public)")
        let timer = Timer(timeInterval: 1.0 / 60, target: self,
                          selector: #selector(stepAnimation(_:)),
                          userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self, weak window] event in
            // The second click that opens the wheel can still be in flight
            // while this monitor is installed. Do not mistake it for a click
            // outside the wheel.
            if let self, self.isVisible,
               ProcessInfo.processInfo.systemUptime - self.shownAt > 0.5,
               event.window !== window {
                NSLog("CodexQuotaPet radial wheel dismissed by local outside click")
                self.dismiss()
            }
            return event
        }
    }

    @objc private func stepAnimation(_ timer: Timer) {
        guard let view = wheelView else {
            timer.invalidate()
            return
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - animationStartedAt
        let linear = min(1, max(0, elapsed / 0.26))
        // A short ease-out gives the spokes a physical unfolding motion.
        view.progress = CGFloat(0.15 + 0.85 * (1 - pow(1 - linear, 3)))
        if linear >= 1 {
            timer.invalidate()
            animationTimer = nil
            if let panel {
                wheelLogger.info("settled visible=\(panel.isVisible, privacy: .public) occluded=\(!panel.occlusionState.contains(.visible), privacy: .public)")
            }
        }
    }

    func dismiss() {
        if isVisible { NSLog("CodexQuotaPet radial wheel dismissed") }
        pendingPresentationID = nil
        animationTimer?.invalidate()
        animationTimer = nil
        if let monitor = localClickMonitor { NSEvent.removeMonitor(monitor) }
        localClickMonitor = nil
        panel?.orderOut(nil)
        panel = nil
        wheelView = nil
    }
}

@MainActor
private final class RadialWheelView: NSView {
    var selectedMode: RadialWheel.Action = .arc { didSet { needsDisplay = true } }
    var autoOpenStatus: String? { didSet { needsDisplay = true } }
    var progress: CGFloat = 0 { didSet { needsDisplay = true } }
    var onAction: ((RadialWheel.Action) -> Void)?
    var onDismiss: (() -> Void)?
    private var hoveredAction: RadialWheel.Action? { didSet { needsDisplay = true } }
    private var hubHovered = false { didSet { needsDisplay = true } }

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited,
                                                 .activeAlways], owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hoveredAction = action(at: point)
        hubHovered = hoveredAction == nil && isHub(point)
    }

    override func mouseExited(with event: NSEvent) {
        hoveredAction = nil
        hubHovered = false
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if isHub(point) {
            onDismiss?()
        } else if let action = action(at: point) {
            onAction?(action)
        } else {
            onDismiss?()
        }
    }

    override func rightMouseDown(with event: NSEvent) { onDismiss?() }

    private var scale: CGFloat { min(bounds.width, bounds.height) / RadialWheel.preferredSide }
    private var hub: NSPoint { NSPoint(x: bounds.midX, y: bounds.midY) }
    private var buttonRadius: CGFloat { RadialWheel.buttonRadius(in: bounds) }
    private var hubRadius: CGFloat { RadialWheel.hubRadius(in: bounds) }

    private func isHub(_ point: NSPoint) -> Bool {
        hypot(point.x - hub.x, point.y - hub.y) <= hubRadius
    }

    private func action(at point: NSPoint) -> RadialWheel.Action? {
        guard progress > 0.9, !isHub(point) else { return nil }
        for action in RadialWheel.Action.allCases {
            let center = RadialWheel.buttonCenter(for: action, in: bounds, progress: progress)
            if hypot(point.x - center.x, point.y - center.y) <= buttonRadius {
                return action
            }
        }
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let side = min(bounds.width, bounds.height)
        let discSide = side * (0.29 + 0.69 * progress)
        let backdrop = NSBezierPath(ovalIn: NSRect(x: hub.x - discSide / 2,
                                                   y: hub.y - discSide / 2,
                                                   width: discSide,
                                                   height: discSide))
        NSGraphicsContext.saveGraphicsState()
        let halo = NSShadow()
        halo.shadowColor = NSColor(calibratedRed: 0.30, green: 0.25, blue: 0.51, alpha: 0.19)
        halo.shadowOffset = NSSize(width: 0, height: -3 * scale)
        halo.shadowBlurRadius = 14 * scale
        halo.set()
        NSGradient(starting: NSColor(calibratedRed: 0.995, green: 0.990, blue: 1, alpha: 0.94),
                   ending: NSColor(calibratedRed: 0.87, green: 0.85, blue: 0.98, alpha: 0.88))?
            .draw(in: backdrop, angle: 105)
        NSGraphicsContext.restoreGraphicsState()
        NSColor(calibratedRed: 0.66, green: 0.62, blue: 0.85, alpha: 0.9).setStroke()
        backdrop.lineWidth = 2 * scale
        backdrop.stroke()

        let spokeColor = NSColor(calibratedRed: 0.48, green: 0.43, blue: 0.74,
                                 alpha: 0.75 * progress)
        spokeColor.setStroke()
        for action in RadialWheel.Action.allCases {
            let button = RadialWheel.buttonCenter(for: action, in: bounds, progress: progress)
            let spoke = NSBezierPath()
            spoke.lineCapStyle = .round
            spoke.lineWidth = 3 * scale
            spoke.move(to: NSPoint(x: hub.x + action.direction.x * hubRadius,
                                   y: hub.y + action.direction.y * hubRadius))
            spoke.line(to: NSPoint(x: button.x - action.direction.x * buttonRadius * 0.72,
                                   y: button.y - action.direction.y * buttonRadius * 0.72))
            spoke.stroke()
        }
        for action in RadialWheel.Action.allCases {
            drawButton(action)
        }
        drawHub()
    }

    private func drawButton(_ action: RadialWheel.Action) {
        let center = RadialWheel.buttonCenter(for: action, in: bounds, progress: progress)
        let selected = action == selectedMode
        let hovered = action == hoveredAction
        let radius = buttonRadius * (0.74 + 0.26 * progress)
        let path = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                               width: radius * 2, height: radius * 2))
        let highlight = selected || hovered
        let top = highlight
            ? NSColor(calibratedRed: 0.81, green: 0.77, blue: 0.98, alpha: 1)
            : NSColor(calibratedRed: 1, green: 1, blue: 1, alpha: 0.99)
        let bottom = highlight
            ? NSColor(calibratedRed: 0.68, green: 0.61, blue: 0.91, alpha: 1)
            : NSColor(calibratedRed: 0.95, green: 0.93, blue: 1, alpha: 0.97)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(calibratedRed: 0.32, green: 0.27, blue: 0.53, alpha: 0.22)
        shadow.shadowOffset = NSSize(width: 0, height: -2 * scale)
        shadow.shadowBlurRadius = 6 * scale
        shadow.set()
        NSGradient(starting: top, ending: bottom)?.draw(in: path, angle: 90)
        NSGraphicsContext.restoreGraphicsState()
        (highlight ? NSColor(calibratedRed: 0.43, green: 0.34, blue: 0.72, alpha: 1)
                   : NSColor(calibratedRed: 0.67, green: 0.63, blue: 0.82, alpha: 1)).setStroke()
        path.lineWidth = (selected ? 3 : 2) * scale
        path.stroke()
        let textColor = NSColor(calibratedRed: 0.24, green: 0.20, blue: 0.40, alpha: progress)
        if action == .autoOpen, let status = autoOpenStatus, !status.isEmpty {
            drawAutoOpenLabel(status, at: center, color: textColor, selected: selected)
            return
        }
        let lines = action.titleLines
        let font = NSFont.systemFont(ofSize: (lines.count == 1 ? 15 : 14) * scale,
                                     weight: selected ? .bold : .semibold)
        let lineHeight = 18 * scale
        let totalHeight = CGFloat(lines.count) * lineHeight
        for (index, line) in lines.enumerated() {
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
            let text = line as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: center.x - size.width / 2,
                                  y: center.y + totalHeight / 2 - CGFloat(index + 1) * lineHeight + 1 * scale),
                      withAttributes: attributes)
        }
        if selected {
            let dot = NSBezierPath(ovalIn: NSRect(x: center.x - 3 * scale,
                                                  y: center.y - radius + 10 * scale,
                                                  width: 6 * scale, height: 6 * scale))
            NSColor(calibratedRed: 0.40, green: 0.31, blue: 0.72, alpha: 1).setFill()
            dot.fill()
        }
    }

    private func drawAutoOpenLabel(_ status: String, at center: NSPoint,
                                   color: NSColor, selected: Bool) {
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13 * scale,
                                     weight: selected ? .bold : .semibold),
            .foregroundColor: color
        ]
        let subtitleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10 * scale, weight: .medium),
            .foregroundColor: color
        ]
        let title = "自动打开" as NSString
        let subtitle = (status.count > 6 ? String(status.prefix(5)) + "…" : status) as NSString
        let titleSize = title.size(withAttributes: titleAttributes)
        let subtitleSize = subtitle.size(withAttributes: subtitleAttributes)
        title.draw(at: NSPoint(x: center.x - titleSize.width / 2,
                               y: center.y + 2 * scale),
                   withAttributes: titleAttributes)
        subtitle.draw(at: NSPoint(x: center.x - subtitleSize.width / 2,
                                  y: center.y - 14 * scale),
                      withAttributes: subtitleAttributes)
    }

    private func drawHub() {
        let radius = hubRadius
        let path = NSBezierPath(ovalIn: NSRect(x: hub.x - radius, y: hub.y - radius,
                                               width: radius * 2, height: radius * 2))
        let top = hubHovered
            ? NSColor(calibratedRed: 0.71, green: 0.66, blue: 0.92, alpha: 1)
            : NSColor(calibratedRed: 0.81, green: 0.77, blue: 0.96, alpha: 1)
        let bottom = NSColor(calibratedRed: 0.62, green: 0.56, blue: 0.85, alpha: 1)
        NSGradient(starting: top, ending: bottom)?.draw(in: path, angle: 90)
        NSColor(calibratedRed: 0.37, green: 0.30, blue: 0.65, alpha: 1).setStroke()
        path.lineWidth = 2 * scale
        path.stroke()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13 * scale, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let text = "收起" as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: hub.x - size.width / 2, y: hub.y - size.height / 2),
                  withAttributes: attributes)
    }
}
