import AppKit

private struct RainParticle {
    var position: NSPoint
    let size: CGFloat
    let horizontalSpeed: CGFloat
    let fallSpeed: CGFloat
    let imageIndex: Int
}

@MainActor
private final class RainView: NSView {
    var images: [NSImage] = []
    var particles: [RainParticle] = [] {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for particle in particles {
            guard images.indices.contains(particle.imageIndex) else { continue }
            let rect = NSRect(x: particle.position.x, y: particle.position.y,
                              width: particle.size, height: particle.size)
            if rect.intersects(dirtyRect) {
                images[particle.imageIndex].draw(in: rect, from: .zero,
                                                 operation: .sourceOver, fraction: 1)
            }
        }
    }
}

/// A single click-through window draws the whole rain, so a dense shower does
/// not create hundreds of separate macOS windows.
@MainActor
final class RainOverlay {
    private let spawnRate = 48.0
    private let maximumVisibleParticles = 300
    private var panel: NSPanel?
    private var rainView: RainView?
    private var timer: Timer?
    private var lastTickAt: TimeInterval = 0
    private var spawnUntil: TimeInterval = 0
    private var spawnRemainder = 0.0
    private var requestedDuration: TimeInterval = 0
    private var pendingPresentationID: UUID?

    func start(on screen: NSScreen?, spriteImages: [NSImage], duration: TimeInterval) {
        guard let screen = screen ?? NSScreen.main ?? NSScreen.screens.first,
              !spriteImages.isEmpty, duration > 0 else { return }

        stop()

        // NSScreen.frame includes the menu bar and Dock areas. Its origin may
        // be negative on secondary displays; the view itself uses local coords.
        let frame = screen.frame
        let window = NSPanel(contentRect: frame,
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = RainView(frame: NSRect(origin: .zero, size: frame.size))
        view.images = spriteImages
        window.contentView = view
        panel = window
        rainView = view
        requestedDuration = duration
        let presentationID = UUID()
        pendingPresentationID = presentationID
        NSLog("CodexQuotaPet rain window queued")

        // Menu actions can run while AppKit is still tracking the menu. Showing
        // a wholly transparent panel there may leave its first frame waiting
        // for the next Space/compositor update. Present it in the default run
        // loop mode, after menu tracking has finished, with content already
        // drawn into its backing store.
        RunLoop.main.perform(inModes: [.default]) { [weak self] in
            Task { @MainActor [weak self] in
                self?.present(if: presentationID)
            }
        }
    }

    private func present(if presentationID: UUID) {
        guard pendingPresentationID == presentationID,
              let window = panel, let view = rainView else { return }
        pendingPresentationID = nil
        seedFirstFrame(in: view)
        window.display()
        window.orderFrontRegardless()
        window.displayIfNeeded()
        NSLog("CodexQuotaPet rain window presented")
        beginAnimation()
    }

    private func seedFirstFrame(in view: RainView) {
        // A nonempty first frame makes the new transparent window visible to
        // the compositor immediately; subsequent sprites still fall in from
        // above the screen as usual.
        var first: [RainParticle] = []
        for _ in 0..<8 {
            let size = CGFloat.random(in: 35...75)
            let x = CGFloat.random(in: -size / 2...(view.bounds.width - size / 2))
            let y = view.bounds.height - size * CGFloat.random(in: 0.7...1.0)
            first.append(RainParticle(position: NSPoint(x: x, y: y),
                                      size: size,
                                      horizontalSpeed: CGFloat.random(in: -22...22),
                                      fallSpeed: CGFloat.random(in: 180...300),
                                      imageIndex: Int.random(in: view.images.indices)))
        }
        view.particles = first
    }

    private func beginAnimation() {
        let now = ProcessInfo.processInfo.systemUptime
        lastTickAt = now
        spawnUntil = now + requestedDuration
        spawnRemainder = 0

        let displayTimer = Timer(timeInterval: 1.0 / 60.0,
                                 target: self, selector: #selector(advance),
                                 userInfo: nil, repeats: true)
        RunLoop.main.add(displayTimer, forMode: .common)
        timer = displayTimer
    }

    private func stop() {
        pendingPresentationID = nil
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        rainView = nil
    }

    @objc private func advance() {
        guard let view = rainView else { stop(); return }
        let now = ProcessInfo.processInfo.systemUptime
        let delta = CGFloat(max(0, min(now - lastTickAt, 0.1)))
        let spawningSeconds = max(0, min(now, spawnUntil) - min(lastTickAt, spawnUntil))
        lastTickAt = now

        var next = view.particles
        for index in next.indices {
            next[index].position.x += next[index].horizontalSpeed * delta
            next[index].position.y -= next[index].fallSpeed * delta
        }
        // Remove sprites only after their entire image has moved below the
        // screen. Their opacity stays at 100% throughout the fall.
        next.removeAll { $0.position.y + $0.size < 0 }

        spawnRemainder += spawningSeconds * spawnRate
        let requestedCount = Int(spawnRemainder)
        spawnRemainder -= Double(requestedCount)
        if requestedCount > 0 {
            for _ in 0..<min(requestedCount, max(0, maximumVisibleParticles - next.count)) {
                let size = CGFloat.random(in: 35...75)
                let x = CGFloat.random(in: -size / 2...(view.bounds.width - size / 2))
                let y = view.bounds.height + CGFloat.random(in: 0...size * 0.35)
                next.append(RainParticle(position: NSPoint(x: x, y: y),
                                         size: size,
                                         horizontalSpeed: CGFloat.random(in: -22...22),
                                         fallSpeed: CGFloat.random(in: 180...300),
                                         imageIndex: Int.random(in: view.images.indices)))
            }
        }
        view.particles = next

        if now >= spawnUntil && next.isEmpty { stop() }
    }
}
