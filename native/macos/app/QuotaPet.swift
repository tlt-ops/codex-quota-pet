import AppKit
import CoreGraphics
import CoreImage
import ImageIO

private let windowSide: CGFloat = 400
private let quotaURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/CodexQuotaPet/quota.json")

private enum AutoOpenSetup {
    static let label = "com.codexquotapet.watcher"
    static let supportDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CodexQuotaPet")
    static let installedApp = supportDirectory.appendingPathComponent("Codex Quota Pet.app")
    static let installedWatcher = supportDirectory.appendingPathComponent("watch_codex.py")
    static let agentPlist = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/\(label).plist")

    static func isReady(sourceApp: URL, watcher: URL) -> Bool {
        let files = FileManager.default
        let currentExecutable = sourceApp.appendingPathComponent("Contents/MacOS/CodexQuotaPet")
        let installedExecutable = installedApp.appendingPathComponent("Contents/MacOS/CodexQuotaPet")
        guard files.fileExists(atPath: agentPlist.path),
              files.fileExists(atPath: installedWatcher.path),
              files.fileExists(atPath: installedExecutable.path),
              files.contentsEqual(atPath: watcher.path,
                                  andPath: installedWatcher.path),
              files.contentsEqual(atPath: currentExecutable.path,
                                  andPath: installedExecutable.path) else { return false }
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        check.arguments = ["print", "gui/\(getuid())/\(label)"]
        check.standardOutput = FileHandle.nullDevice
        check.standardError = FileHandle.nullDevice
        do { try check.run() } catch { return false }
        return waitForProcess(check, seconds: 8)
    }

    static func install(installer: URL, watcher: URL, sourceApp: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [installer.path, "--app", sourceApp.path,
                             "--watcher", watcher.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        return waitForProcess(process, seconds: 90)
    }

    private static func waitForProcess(_ process: Process, seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            return false
        }
        return process.terminationStatus == 0
    }
}

private struct QuotaSnapshot {
    var status = "loading"
    var updatedAt: TimeInterval = 0
    var lines = ["正在读取额度…"]
    var detail = ""
}

/// Resolves a character click streak only after another click has had time to
/// arrive. Keeping the buffered launches lets a third press turn all taps in
/// that streak into ordinary projectile launches without ever showing a wheel.
struct PetClickSequence {
    struct Launch {
        let point: NSPoint
        let duration: TimeInterval
    }

    enum Action {
        case launch(Launch)
        case wheel(NSPoint)
    }

    private let doubleClickInterval: TimeInterval
    private let timerGrace: TimeInterval
    private var streak = 0
    private var lastInteractionAt: TimeInterval?
    private var activePress = false
    private var suppressed = false
    private var pending: [Launch] = []
    private var wheelPoint: NSPoint?
    private(set) var deadline: TimeInterval?

    init(doubleClickInterval: TimeInterval, timerGrace: TimeInterval = 0.03) {
        self.doubleClickInterval = doubleClickInterval
        self.timerGrace = timerGrace
    }

    mutating func beginCharacter(at time: TimeInterval, clickCount: Int) -> [Action] {
        var actions: [Action] = []
        // A timer can be late while AppKit is tracking another event. If
        // AppKit still reports a continuing click streak, let that press
        // cancel a pending wheel before resolving the old timer.
        if let lastInteractionAt,
           time - lastInteractionAt > doubleClickInterval + timerGrace,
           !(clickCount >= 2 && streak > 0) {
            actions = settlePending()
            streak = 0
            suppressed = false
        }
        lastInteractionAt = time
        streak += 1
        activePress = true
        // AppKit also enforces its spatial double-click threshold. If it says
        // this is a new gesture, do not turn nearby rapid taps into a wheel.
        if clickCount > 0 && clickCount != streak { suppressed = true }
        if streak >= 3 { suppressed = true }
        if suppressed { actions += drainPendingAsLaunches() }
        return actions
    }

    mutating func endCharacter(at time: TimeInterval, point: NSPoint,
                               duration: TimeInterval, valid: Bool,
                               longPress: Bool) -> [Action] {
        guard activePress else { return [] }
        activePress = false
        lastInteractionAt = time
        if !valid {
            suppressed = true
            return drainPendingAsLaunches()
        }
        let launch = Launch(point: point, duration: duration)
        if longPress {
            suppressed = true
            return drainPendingAsLaunches() + [.launch(launch)]
        }
        if suppressed || streak > 2 {
            return drainPendingAsLaunches() + [.launch(launch)]
        }
        pending.append(launch)
        wheelPoint = streak == 2 ? point : nil
        deadline = time + doubleClickInterval + timerGrace
        return []
    }

    /// A bubble, other surface, or right click interrupts the left-click
    /// gesture; any completed character taps retain their projectile action.
    mutating func interrupt(at time: TimeInterval) -> [Action] {
        let actions = drainPendingAsLaunches()
        if let lastInteractionAt,
           time - lastInteractionAt <= doubleClickInterval + timerGrace {
            suppressed = true
        } else {
            streak = 0
            suppressed = false
        }
        lastInteractionAt = time
        activePress = false
        return actions
    }

    mutating func resolveDue(at time: TimeInterval) -> [Action] {
        guard let deadline, time >= deadline else { return [] }
        return settlePending()
    }

    private mutating func settlePending() -> [Action] {
        if pending.count == 2 && streak == 2 && !suppressed,
           let wheelPoint {
            pending = []
            self.wheelPoint = nil
            deadline = nil
            return [.wheel(wheelPoint)]
        }
        return drainPendingAsLaunches()
    }

    private mutating func drainPendingAsLaunches() -> [Action] {
        let actions = pending.map { Action.launch($0) }
        pending = []
        wheelPoint = nil
        deadline = nil
        return actions
    }
}

@MainActor
private protocol PetInteractionDelegate: AnyObject {
    func petClicked(at screenPoint: NSPoint, holdDuration: TimeInterval)
    func petDoubleClicked(at screenPoint: NSPoint)
    func petBubbleMenu() -> NSMenu
    func petContextMenu() -> NSMenu
}

@MainActor
private final class PetView: NSView {
    weak var interactionDelegate: PetInteractionDelegate?
    var portrait: NSImage?
    private var bubbleLayer: NSImage?
    private var characterLayer: NSImage?
    private var characterCI: CIImage?
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var pressedPortraits: [NSImage] = []
    var snapshot = QuotaSnapshot() { didSet { needsDisplay = true; toolTip = snapshot.detail } }
    private var mouseStart = NSPoint.zero
    private var mouseDownAt: TimeInterval = 0
    private var didDrag = false
    private var pressed = false
    private var mouseDownOnCharacter = false
    private var mouseDownOnBubble = false
    private var pressTimer: Timer?
    private var clickSequence = PetClickSequence(doubleClickInterval: NSEvent.doubleClickInterval)
    private var clickSequenceTimer: Timer?

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let destination = NSRect(x: 0, y: -8, width: bounds.width, height: bounds.height)
        var image = characterLayer
        if pressed && !pressedPortraits.isEmpty {
            let elapsed = ProcessInfo.processInfo.systemUptime - mouseDownAt
            let index = min(pressedPortraits.count - 1, Int(max(0, elapsed) / 0.12))
            image = pressedPortraits[index]
        }
        if let image, let bubbleLayer {
            image.draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1)
            let graphics = NSGraphicsContext.current
            graphics?.saveGraphicsState()
            graphics?.shouldAntialias = false
            bubblePathInView().addClip()
            bubbleLayer.draw(in: destination, from: .zero, operation: .copy, fraction: 1)
            graphics?.restoreGraphicsState()
        } else {
            portrait?.draw(in: destination, from: .zero, operation: .sourceOver, fraction: 1)
        }

        let scale = bounds.width / windowSide
        let textColor = snapshot.status == "error"
            ? NSColor(calibratedRed: 0.53, green: 0.21, blue: 0.31, alpha: 1)
            : NSColor(calibratedRed: 0.20, green: 0.19, blue: 0.29, alpha: 1)
        let displayLines = Array(snapshot.lines.prefix(3))
        let firstY: CGFloat = displayLines.count == 1 ? 288 : 320
        for (index, line) in displayLines.enumerated() {
            drawLine(line, x: 34 * scale, y: (firstY - CGFloat(index) * 32) * scale,
                     width: 201 * scale,
                     font: .systemFont(ofSize: 16 * scale, weight: .semibold), color: textColor)
        }
    }

    private func drawLine(_ input: String, x: CGFloat, y: CGFloat, width: CGFloat,
                          font: NSFont, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        var line = input.replacingOccurrences(of: "\n", with: " ")
        if (line as NSString).size(withAttributes: attributes).width > width {
            while line.count > 1 {
                line.removeLast()
                let candidate = line + "…"
                if (candidate as NSString).size(withAttributes: attributes).width <= width {
                    line = candidate
                    break
                }
            }
        }
        let lineWidth = (line as NSString).size(withAttributes: attributes).width
        (line as NSString).draw(at: NSPoint(x: x + max(0, (width - lineWidth) / 2), y: y),
                                withAttributes: attributes)
    }

    func configurePortrait(at url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let original = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        let size = NSSize(width: original.width, height: original.height)
        portrait = NSImage(cgImage: original, size: size)

        // Split the original drawing into disjoint layers. The generous oval
        // covers the hand-drawn speech-bubble rim and its tail. The two smaller
        // ovals preserve the thought dots as part of the fixed bubble layer.
        let bubblePath = NSBezierPath(ovalIn: NSRect(x: 26, y: 733, width: 732, height: 467))
        bubblePath.appendOval(in: NSRect(x: 268, y: 653, width: 98, height: 80))
        bubblePath.appendOval(in: NSRect(x: 352, y: 591, width: 79, height: 72))
        let wholeRect = NSRect(origin: .zero, size: size)
        let characterPath = NSBezierPath(rect: wholeRect)
        characterPath.append(bubblePath)
        characterPath.windingRule = .evenOdd

        guard let bubbleCG = renderLayer(original: portrait!, clippedTo: bubblePath, size: size),
              let characterCG = renderLayer(original: portrait!, clippedTo: characterPath,
                                            size: size) else { return }
        bubbleLayer = NSImage(cgImage: bubbleCG, size: size)
        characterLayer = NSImage(cgImage: characterCG, size: size)
        characterCI = CIImage(cgImage: characterCG)
        needsDisplay = true
    }

    private func renderLayer(original: NSImage, clippedTo clip: NSBezierPath,
                             size: NSSize) -> CGImage? {
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                           pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                           isPlanar: false, colorSpaceName: .deviceRGB,
                                           bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        graphics.shouldAntialias = false
        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        clip.addClip()
        original.draw(in: NSRect(origin: .zero, size: size), from: .zero,
                      operation: .sourceOver, fraction: 1)
        graphics.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.cgImage
    }

    private func preparePressedPortraits(at point: NSPoint) {
        guard let base = characterCI,
              let filter = CIFilter(name: "CIPinchDistortion") else { return }
        let center = CIVector(
            x: base.extent.minX + point.x / bounds.width * base.extent.width,
            y: base.extent.minY + (point.y + 8) / bounds.height * base.extent.height
        )
        var variants: [NSImage] = []
        for strength in [0.06, 0.11, 0.17, 0.23, 0.28] {
            filter.setValue(base, forKey: kCIInputImageKey)
            filter.setValue(center, forKey: kCIInputCenterKey)
            filter.setValue(170, forKey: kCIInputRadiusKey)
            filter.setValue(strength, forKey: kCIInputScaleKey)
            guard let output = filter.outputImage else { continue }
            let right = base.cropped(to: CGRect(x: base.extent.maxX - 14, y: 0,
                                                width: 14, height: base.extent.height))
            let bottom = base.cropped(to: CGRect(x: 0, y: 0,
                                                 width: base.extent.width, height: 30))
            let protected = right.composited(over: bottom.composited(over: output))
            guard let rendered = ciContext.createCGImage(protected, from: base.extent) else { continue }
            variants.append(NSImage(cgImage: rendered,
                                    size: NSSize(width: rendered.width, height: rendered.height)))
        }
        pressedPortraits = variants
    }

    func showPressedPreview(at point: NSPoint) {
        mouseDownAt = ProcessInfo.processInfo.systemUptime - 0.7
        preparePressedPortraits(at: point)
        pressed = true
        needsDisplay = true
    }


    override func mouseDown(with event: NSEvent) {
        mouseStart = NSEvent.mouseLocation
        mouseDownAt = ProcessInfo.processInfo.systemUptime
        didDrag = false
        let point = convert(event.locationInWindow, from: nil)
        mouseDownOnBubble = isBubblePoint(point)
        mouseDownOnCharacter = isCharacterPoint(point) && !mouseDownOnBubble
        let actions = mouseDownOnCharacter
            ? clickSequence.beginCharacter(at: mouseDownAt, clickCount: event.clickCount)
            : clickSequence.interrupt(at: mouseDownAt)
        scheduleClickSequenceTimer()
        performClickActions(actions)
        pressed = mouseDownOnCharacter
        if pressed { preparePressedPortraits(at: point) }
        needsDisplay = true
        pressTimer?.invalidate()
        if pressed {
            pressTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                self?.needsDisplay = true
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let now = NSEvent.mouseLocation
        if hypot(now.x - mouseStart.x, now.y - mouseStart.y) > 5 { didDrag = true }
    }

    override func mouseUp(with event: NSEvent) {
        pressed = false
        pressTimer?.invalidate()
        pressTimer = nil
        pressedPortraits = []
        needsDisplay = true
        let point = convert(event.locationInWindow, from: nil)
        if mouseDownOnCharacter {
            let now = ProcessInfo.processInfo.systemUptime
            let duration = max(0, now - mouseDownAt)
            let valid = !didDrag && isCharacterPoint(point) && !isBubblePoint(point)
            let actions = clickSequence.endCharacter(
                at: now, point: screenPoint(for: event), duration: duration,
                valid: valid,
                longPress: duration >= max(0.5, NSEvent.doubleClickInterval * 2))
            scheduleClickSequenceTimer()
            performClickActions(actions)
        } else if !didDrag && mouseDownOnBubble && isBubblePoint(point),
                  let menu = interactionDelegate?.petBubbleMenu() {
            menu.popUp(positioning: nil, at: point, in: self)
        }
    }

    private func performClickActions(_ actions: [PetClickSequence.Action]) {
        for action in actions {
            switch action {
            case .launch(let launch):
                interactionDelegate?.petClicked(at: launch.point, holdDuration: launch.duration)
            case .wheel(let point):
                NSLog("CodexQuotaPet exact two character clicks: opening radial wheel at %@",
                      NSStringFromPoint(point))
                interactionDelegate?.petDoubleClicked(at: point)
            }
        }
    }

    private func scheduleClickSequenceTimer() {
        clickSequenceTimer?.invalidate()
        clickSequenceTimer = nil
        guard let deadline = clickSequence.deadline else { return }
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        let timer = Timer(timeInterval: delay, target: self,
                          selector: #selector(finishClickSequence(_:)),
                          userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        clickSequenceTimer = timer
    }

    @objc private func finishClickSequence(_ timer: Timer) {
        clickSequenceTimer = nil
        performClickActions(clickSequence.resolveDue(at: ProcessInfo.processInfo.systemUptime))
        scheduleClickSequenceTimer()
    }

    private func screenPoint(for event: NSEvent) -> NSPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }

    private func isBubblePoint(_ point: NSPoint) -> Bool {
        bubblePathInView().contains(point)
    }

    private func bubblePathInView() -> NSBezierPath {
        let factor = bounds.width / 1254
        let path = NSBezierPath(ovalIn: NSRect(x: 26 * factor,
                                             y: 733 * factor - 8,
                                             width: 732 * factor,
                                             height: 467 * factor))
        path.appendOval(in: NSRect(x: 268 * factor, y: 653 * factor - 8,
                                   width: 98 * factor, height: 80 * factor))
        path.appendOval(in: NSRect(x: 352 * factor, y: 591 * factor - 8,
                                   width: 79 * factor, height: 72 * factor))
        return path
    }

    private func isCharacterPoint(_ point: NSPoint) -> Bool {
        // The speech bubble occupies the upper left. The body and head occupy
        // the lower and right parts of this otherwise transparent square.
        (point.x > 105 && point.y < 260) || (point.x > 145 && point.y < 320)
    }

    override func rightMouseDown(with event: NSEvent) {
        let actions = clickSequence.interrupt(at: ProcessInfo.processInfo.systemUptime)
        scheduleClickSequenceTimer()
        performClickActions(actions)
        let point = convert(event.locationInWindow, from: nil)
        if isCharacterPoint(point) && !isBubblePoint(point) {
            NSLog("CodexQuotaPet secondary click on character at %@: opening radial wheel",
                  NSStringFromPoint(point))
            interactionDelegate?.petDoubleClicked(at: screenPoint(for: event))
        } else if let menu = interactionDelegate?.petContextMenu() {
            NSLog("CodexQuotaPet secondary click outside character at %@: context menu",
                  NSStringFromPoint(point))
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, PetInteractionDelegate {
    private enum LaunchMode: String {
        case arc
        case bounce

        var title: String { self == .bounce ? "弹射" : "抛物线" }
    }

    private struct Particle {
        let window: NSPanel
        let mode: LaunchMode
        let start: NSPoint
        var position: NSPoint
        var vx: CGFloat
        var vy: CGFloat
        let gravity: CGFloat
        let startAt: TimeInterval
        var lastTickAt: TimeInterval
        let screenFrame: NSRect
        var bounceCount = 0
        var fadeStartedAt: TimeInterval?
    }
    private var panel: NSPanel!
    private var petView: PetView!
    private var statusItem: NSStatusItem!
    private let radialWheel = RadialWheel()
    private var snapshot = QuotaSnapshot()
    private let quotaSoundPlayer = QuotaSoundPlayer()
    private var quotaSoundDetector = QuotaSoundDetector(startedAt: Date().timeIntervalSince1970)
    private var quotaResetSoundTimer: Timer?
    private var launchMode = LaunchMode(rawValue: UserDefaults.standard.string(forKey: "launchMode") ?? "") ?? .arc
    private var refreshInProgress = false
    private var particles: [UUID: Particle] = [:]
    private var particleTimer: Timer?
    private var stickerImages: [NSImage] = []
    private let rainOverlay = RainOverlay()
    private var autoOpenBusy = false
    private var autoOpenStatus = "检查中"
    private var installedInstanceTimer: Timer?
    private var observedInstalledInstance: (pid: pid_t, firstSeen: TimeInterval)?
    private var visibilityIntent = PetVisibilityIntent()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // Check durable Hide/Quit before creating a visible panel: the watcher
        // may restart us while the same Codex process is still running.
        let showOnLaunch = shouldShowPet(codexPIDs: runningCodexPIDs())
        makePanel(showOnLaunch: showOnLaunch)
        makeStatusItem()
        stickerImages = loadStickerImages()
        quotaSoundPlayer.prepare()
        readQuota()
        refreshQuota()
        setupAutoOpen(force: false)
        Timer.scheduledTimer(timeInterval: 10, target: self,
                             selector: #selector(readQuota), userInfo: nil, repeats: true)
        Timer.scheduledTimer(timeInterval: 60, target: self,
                             selector: #selector(refreshQuota), userInfo: nil, repeats: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        // The watcher sends reopen events on Codex activation as well as
        // launch. Decide when the callback runs so a Hide between this event
        // and the queued work cannot be undone by a Space switch.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel != nil,
                  self.shouldShowPet(codexPIDs: self.runningCodexPIDs()) else {
                return
            }
            self.anchorPanel()
            self.panel.orderFrontRegardless()
        }
        // The pet manages its own borderless panel; AppKit should not reopen
        // the window on our behalf while the user's Hide is in effect.
        return false
    }

    private func shouldShowPet(codexPIDs: Set<pid_t>) -> Bool {
        // The watcher clears an old Hide after observing a new Codex PID.
        // Reload its on-disk decision before handling a reopen event, since
        // AppKit may briefly report no Codex PID during that transition.
        visibilityIntent = PetVisibilityIntent()
        do {
            var launchDates = Dictionary(uniqueKeysWithValues:
                NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
                    .filter { !$0.isTerminated && codexPIDs.contains($0.processIdentifier) }
                    .compactMap { app in app.launchDate.map { (app.processIdentifier, $0) } })
            let missing = codexPIDs.subtracting(Set(launchDates.keys))
            launchDates.merge(CodexDesktopProcessLookup.readLaunchDates(pids: missing),
                              uniquingKeysWith: { first, _ in first })
            return try visibilityIntent.shouldShowOnReopen(codexPIDs: codexPIDs, launchDates: launchDates)
        } catch {
            NSLog("CodexQuotaPet cannot clear visibility suppression: %@", error.localizedDescription)
            return false
        }
    }

    private func makePanel(showOnLaunch: Bool) {
        let frame = anchoredFrame()
        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.acceptsMouseMovedEvents = true
        petView = PetView(frame: NSRect(origin: .zero, size: frame.size))
        petView.interactionDelegate = self
        if let url = Bundle.main.url(forResource: "gpt_quota_pet", withExtension: "png") {
            petView.configurePortrait(at: url)
        }
        panel.contentView = petView
        if showOnLaunch { panel.orderFrontRegardless() }
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)
    }

    private func anchoredFrame() -> NSRect {
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(x: screen.maxX - windowSide, y: screen.minY,
                      width: windowSide, height: windowSide)
    }

    @objc private func anchorPanel() {
        panel.setFrame(anchoredFrame(), display: true)
    }

    @objc private func screenParametersChanged() {
        radialWheel.dismiss()
        anchorPanel()
    }

    private func makeStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateAutoOpenMenu()
    }

    private func updateAutoOpenMenu() {
        statusItem.button?.title = launchMode == .bounce ? "◌ 额度 · 弹射" : "◌ 额度"
        statusItem.button?.toolTip = "Codex 额度桌宠 · \(launchMode.title) · 自动打开\(autoOpenStatus)"
        statusItem.menu = petContextMenu()
    }

    private func setupAutoOpen(force: Bool) {
        guard !autoOpenBusy else { return }
        guard let resources = Bundle.main.resourceURL else {
            autoOpenStatus = "缺少安装资源"
            updateAutoOpenMenu()
            return
        }
        let installer = resources.appendingPathComponent("install_launch_agent.py")
        let watcher = resources.appendingPathComponent("watch_codex.py")
        guard FileManager.default.fileExists(atPath: installer.path),
              FileManager.default.fileExists(atPath: watcher.path) else {
            autoOpenStatus = "缺少安装资源"
            updateAutoOpenMenu()
            return
        }
        autoOpenBusy = true
        autoOpenStatus = "设置中"
        updateAutoOpenMenu()
        let sourceApp = Bundle.main.bundleURL
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let success = (!force && AutoOpenSetup.isReady(sourceApp: sourceApp,
                                                          watcher: watcher)) ||
                AutoOpenSetup.install(installer: installer, watcher: watcher, sourceApp: sourceApp)
            DispatchQueue.main.async {
                guard let self else { return }
                self.autoOpenBusy = false
                self.autoOpenStatus = success ? "已设置" : "设置失败"
                self.updateAutoOpenMenu()
                guard success,
                      sourceApp.standardizedFileURL != AutoOpenSetup.installedApp.standardizedFileURL else {
                    return
                }
                // The watcher is the only process that starts the installed copy.
                // Keep this first-run copy visible until the user quits it. If an
                // installed copy stays alive, close this extra copy.
                self.installedInstanceTimer?.invalidate()
                self.observedInstalledInstance = nil
                self.installedInstanceTimer = Timer.scheduledTimer(
                    timeInterval: 2, target: self,
                    selector: #selector(self.checkForInstalledInstance),
                    userInfo: nil, repeats: true)
                self.checkForInstalledInstance()
            }
        }
    }

    @objc private func checkForInstalledInstance() {
        let installed = AutoOpenSetup.installedApp.resolvingSymlinksInPath().standardizedFileURL
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.tanlantian.CodexQuotaPet")
        let installedCopies = running.filter { app in
            guard !app.isTerminated, let url = app.bundleURL else { return false }
            return url.resolvingSymlinksInPath().standardizedFileURL == installed
                && app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        guard installedCopies.count == 1, let app = installedCopies.first else {
            observedInstalledInstance = nil
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        guard let observed = observedInstalledInstance,
              observed.pid == app.processIdentifier else {
            observedInstalledInstance = (pid: app.processIdentifier, firstSeen: now)
            return
        }
        if now - observed.firstSeen >= 5 {
            installedInstanceTimer?.invalidate()
            installedInstanceTimer = nil
            // Internal duplicate cleanup is not a user Quit.
            NSApp.terminate(nil)
        }
    }

    func petContextMenu() -> NSMenu {
        let menu = NSMenu(title: "Codex 额度桌宠")
        menu.addItem(withTitle: "显示", action: #selector(showPet), keyEquivalent: "")
        menu.addItem(withTitle: "隐藏", action: #selector(hidePet), keyEquivalent: "")
        menu.addItem(withTitle: "刷新额度", action: #selector(refreshQuota), keyEquivalent: "")
        menu.addItem(withTitle: "GPT雨", action: #selector(startRain), keyEquivalent: "")
        menu.addItem(withTitle: "发射模式：\(launchMode.title)（打开轮盘）",
                     action: #selector(showRadialWheelFromMenu), keyEquivalent: "")
        let setup = menu.addItem(withTitle: "自动打开：\(autoOpenStatus)",
                                 action: #selector(retryAutoOpen), keyEquivalent: "")
        setup.isEnabled = !autoOpenBusy
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(quitApp), keyEquivalent: "")
        for item in menu.items { item.target = self }
        return menu
    }

    func petBubbleMenu() -> NSMenu {
        let menu = NSMenu(title: "额度动作")
        let item = menu.addItem(withTitle: "GPT雨", action: #selector(startRain), keyEquivalent: "")
        item.target = self
        return menu
    }

    @objc private func startRain() {
        guard !stickerImages.isEmpty else {
            NSLog("CodexQuotaPet rain unavailable: no sticker images")
            return
        }
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first
        NSLog("CodexQuotaPet rain requested")
        rainOverlay.start(on: screen, spriteImages: stickerImages, duration: 10)
    }

    @objc private func retryAutoOpen() { setupAutoOpen(force: true) }

    func petDoubleClicked(at screenPoint: NSPoint) {
        if radialWheel.isVisible {
            radialWheel.dismiss()
        } else {
            showRadialWheel(at: screenPoint)
        }
    }

    @objc private func showRadialWheelFromMenu() {
        // Present after menu tracking ends so the wheel appears in the
        // current Space immediately, as the rain overlay does.
        DispatchQueue.main.async { [weak self] in self?.showRadialWheel() }
    }

    private func showRadialWheel(at screenPoint: NSPoint? = nil) {
        guard panel != nil,
              let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        radialWheel.onSelect = { [weak self] action in
            self?.handleWheelAction(action)
        }
        radialWheel.show(near: panel.frame, on: screen,
                         selectedMode: launchMode == .arc ? .arc : .bounce,
                         at: screenPoint, autoOpenStatus: autoOpenStatus)
    }

    private func handleWheelAction(_ action: RadialWheel.Action) {
        switch action {
        case .show:
            showPet()
        case .hide:
            hidePet()
        case .refresh:
            refreshQuota()
        case .rain:
            startRain()
        case .arc:
            setLaunchMode(.arc)
        case .bounce:
            setLaunchMode(.bounce)
        case .autoOpen:
            retryAutoOpen()
        case .quit:
            quitApp()
        case .testDamage:
            quotaSoundPlayer.testDamage()
        case .testXP:
            quotaSoundPlayer.testXP()
        }
    }

    private func setLaunchMode(_ mode: LaunchMode) {
        launchMode = mode
        UserDefaults.standard.set(launchMode.rawValue, forKey: "launchMode")
        updateAutoOpenMenu()
    }

    private func runningCodexPIDs() -> Set<pid_t> {
        let appKitPIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
            .filter { !$0.isTerminated }
            .map(\.processIdentifier))
        let pids = CodexDesktopProcessLookup.resolve(appKitPIDs: appKitPIDs,
                                                    processListing: CodexDesktopProcessLookup.readProcessListing)
        if appKitPIDs.isEmpty {
            NSLog("CodexQuotaPet desktop PID fallback: %@",
                  pids.isEmpty ? "no identifiable desktop process" : pids.sorted().map(String.init).joined(separator: ","))
        }
        return pids
    }

    @objc private func showPet() {
        do {
            try visibilityIntent.showExplicitly()
        } catch {
            reportVisibilityError(error)
            return
        }
        anchorPanel()
        panel.orderFrontRegardless()
    }

    @objc private func hidePet() {
        do {
            try visibilityIntent.hide(codexPIDs: runningCodexPIDs())
        } catch {
            reportVisibilityError(error)
            return
        }
        radialWheel.dismiss()
        panel.orderOut(nil)
    }

    @objc private func quitApp() {
        do {
            try visibilityIntent.hide(codexPIDs: runningCodexPIDs())
        } catch {
            reportVisibilityError(error)
            return
        }
        radialWheel.dismiss()
        panel.orderOut(nil)
        NSApp.terminate(nil)
    }

    private func reportVisibilityError(_ error: Error) {
        NSLog("CodexQuotaPet cannot save visibility intent: %@", error.localizedDescription)
        let alert = NSAlert()
        alert.messageText = "无法保存桌宠显示状态"
        alert.informativeText = "请检查应用支持目录后重试。\n\(error.localizedDescription)"
        alert.runModal()
    }

    @objc private func readQuota() {
        guard let data = try? Data(contentsOf: quotaURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            if snapshot.status == "loading" {
                snapshot.lines = ["等待额度数据…"]
                petView.snapshot = snapshot
            }
            return
        }
        var next = QuotaSnapshot()
        next.status = json["status"] as? String ?? "error"
        next.updatedAt = (json["updatedAt"] as? NSNumber)?.doubleValue ?? 0
        next.lines = (json["lines"] as? [String])?.filter { !$0.isEmpty } ?? []
        next.detail = json["detail"] as? String ?? ""
        if next.lines.isEmpty {
            next.lines = [next.status == "error" ? "额度读取失败" : "暂无额度数据"]
        }
        snapshot = next
        petView.snapshot = next

        if next.status == "ok",
           let quota = json["quota"] as? [String: Any],
           let bucketId = quota["bucketId"] as? String,
           let windowKind = quota["windowKind"] as? String,
           let usedPercent = (quota["usedPercent"] as? NSNumber)?.doubleValue,
           let remainingPercent = (quota["remainingPercent"] as? NSNumber)?.intValue,
           let sampleId = quota["sampleId"] as? String {
            let sample = QuotaSoundSample(
                bucketId: bucketId,
                windowKind: windowKind,
                windowDurationMins: (quota["windowDurationMins"] as? NSNumber)?.intValue,
                usedPercent: usedPercent,
                remainingPercent: remainingPercent,
                resetsAt: (quota["resetsAt"] as? NSNumber)?.doubleValue,
                availableCount: (quota["availableCount"] as? NSNumber)?.intValue,
                sampleId: sampleId,
                updatedAt: next.updatedAt)
            let events = quotaSoundDetector.accept(sample, now: Date().timeIntervalSince1970)
            if events.damageCount > 0 {
                quotaSoundPlayer.playDamage(count: events.damageCount)
            }
            if events.playXP { quotaSoundPlayer.playXP() }
            scheduleQuotaResetSound()
        } else if next.status == "error" {
            quotaSoundDetector.noteFailure(updatedAt: next.updatedAt)
            scheduleQuotaResetSound()
        }
    }

    private func scheduleQuotaResetSound() {
        quotaResetSoundTimer?.invalidate()
        quotaResetSoundTimer = nil
        guard let deadline = quotaSoundDetector.nextResetAt else { return }
        let seconds = max(0.05, deadline - Date().timeIntervalSince1970)
        let timer = Timer(timeInterval: seconds, target: self,
                          selector: #selector(quotaResetSoundDue),
                          userInfo: nil, repeats: false)
        RunLoop.main.add(timer, forMode: .common)
        quotaResetSoundTimer = timer
    }

    @objc private func quotaResetSoundDue() {
        quotaResetSoundTimer = nil
        if quotaSoundDetector.markResetDue(now: Date().timeIntervalSince1970) {
            quotaSoundPlayer.playXP()
            refreshQuota()
        }
        scheduleQuotaResetSound()
    }

    @objc private func refreshQuota() {
        guard !refreshInProgress,
              let script = Bundle.main.resourceURL?.appendingPathComponent("quota_client.py"),
              FileManager.default.fileExists(atPath: script.path) else {
            readQuota()
            return
        }
        refreshInProgress = true
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshInProgress = false
                self?.readQuota()
            }
        }
        do { try process.run() }
        catch {
            refreshInProgress = false
            if snapshot.status == "loading" {
                snapshot = QuotaSnapshot(status: "error", updatedAt: 0,
                                         lines: ["刷新程序无法启动"], detail: error.localizedDescription)
                petView.snapshot = snapshot
            }
        }
    }

    func petClicked(at screenPoint: NSPoint, holdDuration: TimeInterval) {
        guard let image = stickerImages.randomElement() else { return }
        let side: CGFloat = 78
        let screenFrame = (NSScreen.screens.first { $0.frame.contains(screenPoint) }
                           ?? panel.screen ?? NSScreen.main)?.frame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: screenPoint.x - side / 2, y: screenPoint.y - side / 2)
        if launchMode == .bounce {
            // Keep the entire sticker within the chosen display. This also
            // makes the first collision a visible rebound, not a correction
            // for spawning partly beyond the screen's bottom or right edge.
            origin.x = min(max(origin.x, screenFrame.minX), screenFrame.maxX - side)
            origin.y = min(max(origin.y, screenFrame.minY), screenFrame.maxY - side)
        }
        let start = NSRect(origin: origin, size: NSSize(width: side, height: side))
        let sticker = ParticlePanel(contentRect: start, styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
        sticker.backgroundColor = .clear
        sticker.isOpaque = false
        sticker.hasShadow = false
        sticker.animationBehavior = .none
        sticker.hidesOnDeactivate = false
        sticker.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        sticker.ignoresMouseEvents = true
        sticker.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: start.size))
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        sticker.contentView = imageView
        sticker.orderFrontRegardless()
        let id = UUID()
        let charge = CGFloat(min(1.5, max(0, holdDuration)) / 1.5)
        let speedVariation = launchMode == .bounce ? CGFloat.random(in: 0.94...1.06) : 1
        let angleVariation = launchMode == .bounce ? CGFloat.random(in: -6...6) : 0
        let speed = (320 + 440 * charge) * (launchMode == .bounce ? 1.5 : 1) * speedVariation
        let angle = (30 + 40 * charge + angleVariation) * .pi / 180
        let vx = -speed * cos(angle)
        let vy = speed * sin(angle)
        let duration = 1.0 + 0.5 * charge
        let gravity = launchMode == .arc ? 2 * vy / duration : 0
        let now = ProcessInfo.processInfo.systemUptime
        particles[id] = Particle(window: sticker, mode: launchMode,
                                 start: start.origin, position: start.origin,
                                 vx: vx, vy: vy, gravity: gravity,
                                 startAt: now, lastTickAt: now,
                                 screenFrame: screenFrame)
        if particleTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 60, target: self,
                              selector: #selector(advanceParticles),
                              userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .common)
            particleTimer = timer
        }
    }

    @objc private func advanceParticles() {
        let now = ProcessInfo.processInfo.systemUptime
        var advanced: [UUID: Particle] = [:]
        advanced.reserveCapacity(particles.count)
        for (id, var particle) in particles {
            switch particle.mode {
            case .arc:
                let elapsed = CGFloat(now - particle.startAt)
                particle.position.x = particle.start.x + particle.vx * elapsed
                particle.position.y = particle.start.y + particle.vy * elapsed -
                    0.5 * particle.gravity * elapsed * elapsed
                if particle.position.y + particle.window.frame.height <= particle.screenFrame.minY {
                    particle.window.orderOut(nil)
                    continue
                }
            case .bounce:
                // Use incremental integration so velocity loss affects the
                // distance travelled. Clamp large scheduler gaps when macOS
                // suspends the app or changes Spaces.
                let delta = CGFloat(max(0, min(now - particle.lastTickAt, 0.05)))
                particle.lastTickAt = now
                let bounds = NSRect(origin: particle.screenFrame.origin,
                                    size: NSSize(width: particle.screenFrame.width - particle.window.frame.width,
                                                 height: particle.screenFrame.height - particle.window.frame.height))
                var motion = BounceMotion.State(position: particle.position,
                                                velocity: NSPoint(x: particle.vx, y: particle.vy),
                                                bounceCount: particle.bounceCount)
                BounceMotion.advance(&motion, in: bounds, delta: delta)
                particle.position = motion.position
                particle.vx = motion.velocity.x
                particle.vy = motion.velocity.y
                particle.bounceCount = motion.bounceCount
                if particle.bounceCount >= BounceMotion.maximumBounces && particle.fadeStartedAt == nil {
                    particle.fadeStartedAt = now
                }
                if let fadeStartedAt = particle.fadeStartedAt {
                    let opacity = max(0, 1 - (now - fadeStartedAt) / 1.1)
                    particle.window.alphaValue = CGFloat(opacity)
                    if opacity <= 0 {
                        particle.window.orderOut(nil)
                        continue
                    }
                }
            }
            particle.window.setFrameOrigin(particle.position)
            advanced[id] = particle
        }
        particles = advanced
        if particles.isEmpty {
            particleTimer?.invalidate()
            particleTimer = nil
        }
    }

    fileprivate func loadStickerImages() -> [NSImage] {
        guard let url = Bundle.main.url(forResource: "mini_gpt_sheet_original", withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let whole = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return [] }
        var images: [NSImage] = []
        for row in 0..<4 {
            for column in 0..<6 {
                let x0 = Int((Double(column) * Double(whole.width) / 6).rounded())
                let x1 = Int((Double(column + 1) * Double(whole.width) / 6).rounded())
                let y0 = Int((Double(row) * Double(whole.height) / 4).rounded())
                let y1 = Int((Double(row + 1) * Double(whole.height) / 4).rounded())
                let rect = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
                guard let crop = whole.cropping(to: rect) else { continue }
                let ready = removeWhiteBackground(from: crop) ?? crop
                images.append(NSImage(cgImage: ready,
                                      size: NSSize(width: ready.width, height: ready.height)))
            }
        }
        return images
    }

    private func removeWhiteBackground(from image: CGImage) -> CGImage? {
        let bytesPerRow = image.width * 4
        let count = bytesPerRow * image.height
        let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        defer { bytes.deallocate() }
        bytes.initialize(repeating: 0, count: count)
        guard let context = CGContext(data: bytes, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue |
                                          CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let width = image.width
        let height = image.height
        let total = width * height
        var background = [Bool](repeating: false, count: total)
        var queue: [Int] = []
        queue.reserveCapacity(total / 2)
        func eligible(_ pixel: Int) -> Bool {
            let i = pixel * 4
            let red = Int(bytes[i]), green = Int(bytes[i + 1]), blue = Int(bytes[i + 2])
            return min(red, green, blue) >= 245 && max(red, green, blue) - min(red, green, blue) <= 12
        }
        func enqueue(_ pixel: Int) {
            if !background[pixel] && eligible(pixel) {
                background[pixel] = true
                queue.append(pixel)
            }
        }
        for x in 0..<width { enqueue(x); enqueue((height - 1) * width + x) }
        for y in 0..<height { enqueue(y * width); enqueue(y * width + width - 1) }
        var head = 0
        while head < queue.count {
            let pixel = queue[head]
            head += 1
            let x = pixel % width
            let y = pixel / width
            if x > 0 { enqueue(pixel - 1) }
            if x + 1 < width { enqueue(pixel + 1) }
            if y > 0 { enqueue(pixel - width) }
            if y + 1 < height { enqueue(pixel + width) }
        }
        for pixel in queue {
            let i = pixel * 4
            bytes[i] = 0; bytes[i + 1] = 0; bytes[i + 2] = 0; bytes[i + 3] = 0
        }
        return context.makeImage()
    }
}

#if !PET_CLICK_SEQUENCE_TEST
@main
private struct QuotaPetMain {
    @MainActor
    private static func renderPreview(to directory: URL) {
        guard let asset = Bundle.main.url(forResource: "gpt_quota_pet", withExtension: "png") else { return }
        let view = PetView(frame: NSRect(x: 0, y: 0, width: windowSide, height: windowSide))
        view.configurePortrait(at: asset)
        view.snapshot = QuotaSnapshot(status: "ok", updatedAt: Date().timeIntervalSince1970,
                                      lines: ["额度 53%（7天）", "重置 10-04 12:34", "重置次数 1次"],
                                      detail: "preview")
        try? FileManager.default.createDirectory(at: directory,
                                                  withIntermediateDirectories: true)
        func save(_ name: String) {
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                                pixelsWide: 800, pixelsHigh: 800,
                                                bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0),
                  let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            graphics.cgContext.scaleBy(x: 2, y: 2)
            view.draw(view.bounds)
            graphics.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: directory.appendingPathComponent(name), options: .atomic)
            }
        }
        save("normal.png")
        view.showPressedPreview(at: NSPoint(x: 280, y: 130))
        save("pressed.png")
        if let sticker = AppDelegate().loadStickerImages().first,
           let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: 200, pixelsHigh: 200,
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
           let graphics = NSGraphicsContext(bitmapImageRep: bitmap) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            sticker.draw(in: NSRect(x: 0, y: 0, width: 200, height: 200),
                         from: .zero, operation: .sourceOver, fraction: 1)
            graphics.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: directory.appendingPathComponent("sticker.png"), options: .atomic)
            }
        }
    }

    static func main() {
        MainActor.assumeIsolated {
            let application = NSApplication.shared
            if CommandLine.arguments.count >= 3 && CommandLine.arguments[1] == "--render-preview" {
                renderPreview(to: URL(fileURLWithPath: CommandLine.arguments[2]))
                return
            }
            let delegate = AppDelegate()
            application.delegate = delegate
            application.run()
        }
    }
}
#endif
