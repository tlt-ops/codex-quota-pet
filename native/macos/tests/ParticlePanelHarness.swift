import AppKit
import CoreGraphics
import ImageIO

/// This is an AppKit/WindowServer integration test. Run it in a logged-in
/// desktop session; it creates its own panels and does not automate other apps.
@main
struct ParticlePanelHarness {
    @MainActor static func main() {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        guard let screen = NSScreen.screens.first else { fatalError("No desktop screen") }
        let frame = screen.frame
        let size = NSSize(width: 78, height: 78)
        let start = NSRect(origin: CGPoint(x: frame.midX, y: frame.midY), size: size)
        let old = NSPanel(contentRect: start, styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        let fixed = ParticlePanel(contentRect: start, styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        for panel in [old, fixed] {
            panel.alphaValue = 0
            panel.ignoresMouseEvents = true
            panel.animationBehavior = .none
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.orderFrontRegardless()
        }
        let target = CGPoint(x: frame.midX, y: frame.maxY - size.height)
        old.setFrameOrigin(target)
        let oldError = hypot(old.frame.minX - target.x, old.frame.minY - target.y)
        print("Baseline top-edge displacement: \(oldError) pt; display=\(frame), visible=\(screen.visibleFrame)")

        var placements = 0
        for screen in NSScreen.screens {
            let edge = screen.frame
            for inset: CGFloat in [-40, -1, 0, 1, 10, 34, 60] {
                for point in [CGPoint(x: edge.minX + inset, y: edge.midY),
                              CGPoint(x: edge.maxX - size.width - inset, y: edge.midY),
                              CGPoint(x: edge.midX, y: edge.minY + inset),
                              CGPoint(x: edge.midX, y: edge.maxY - size.height - inset)] {
                    fixed.setFrameOrigin(point)
                    check(hypot(fixed.frame.minX - point.x, fixed.frame.minY - point.y) < 0.01,
                          "actual panel position differs from requested position")
                    placements += 1
                }
            }
        }
        old.orderOut(nil)
        fixed.orderOut(nil)
        print("ParticlePanel PASS: \(placements) actual AppKit edge placements, zero position corrections")

        if CommandLine.arguments.contains("--live") {
            runLive(on: screen)
        }
    }

    @MainActor static func runLive(on screen: NSScreen) {
        let size = NSSize(width: 78, height: 78)
        let edge = screen.frame
        let bounds = NSRect(origin: edge.origin,
                            size: NSSize(width: edge.width - size.width, height: edge.height - size.height))
        let panel = ParticlePanel(contentRect: NSRect(x: edge.midX, y: bounds.maxY - 90,
                                                     width: size.width, height: size.height),
                                  styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = NSImageView(frame: NSRect(origin: .zero, size: size))
        if let path = CommandLine.arguments.dropFirst().first(where: { $0.hasSuffix(".png") }),
           let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
           let crop = image.cropping(to: CGRect(x: 0, y: 0, width: image.width / 6, height: image.height / 4)) {
            view.image = NSImage(cgImage: crop, size: size)
        } else {
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.systemPurple.cgColor
        }
        panel.contentView = view
        panel.orderFrontRegardless()
        var motion = BounceMotion.State(position: panel.frame.origin,
                                        velocity: CGPoint(x: 180, y: 800))
        var samples = 0
        var serverSamples = 0
        var maximumError: CGFloat = 0
        var last = ProcessInfo.processInfo.systemUptime
        var fifthAt: TimeInterval?
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { timer in
            let now = ProcessInfo.processInfo.systemUptime
            // WindowServer commits positioning asynchronously. Sample the
            // previous frame at the next tick, before submitting a new one.
            if let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(panel.windowNumber))
                as? [[String: Any]],
               let item = list.first(where: { ($0[kCGWindowNumber as String] as? Int) == panel.windowNumber }),
               let data = item[kCGWindowBounds as String] as? [String: Any],
               let actual = CGRect(dictionaryRepresentation: data as CFDictionary) {
                let expected = CGRect(x: panel.frame.minX,
                                      y: NSScreen.screens[0].frame.maxY - panel.frame.maxY,
                                      width: size.width, height: size.height)
                check(abs(actual.minX - expected.minX) <= 1 && abs(actual.minY - expected.minY) <= 1,
                      "WindowServer position differs: actual=\(actual), expected=\(expected)")
                serverSamples += 1
            }
            let delta = CGFloat(min(now - last, 0.05))
            last = now
            let oldCount = motion.bounceCount
            BounceMotion.advance(&motion, in: bounds, delta: delta) {
                .init(speedMultiplier: 0.9, angleOffset: 4 * .pi / 180)
            }
            panel.setFrameOrigin(motion.position)
            let error = hypot(panel.frame.minX - motion.position.x, panel.frame.minY - motion.position.y)
            maximumError = max(maximumError, error)
            // AppKit quantizes window origins to whole points on this Mac.
            // Allow less than one point per axis, not the 34-point edge clamp.
            check(abs(panel.frame.minX - motion.position.x) < 1 &&
                  abs(panel.frame.minY - motion.position.y) < 1,
                  "live particle constrained by AppKit: requested=\(motion.position), actual=\(panel.frame.origin), error=\(error)")
            samples += 1
            if oldCount != motion.bounceCount {
                print("Live rebound \(motion.bounceCount): requested=\(motion.position), actual=\(panel.frame.origin)")
            }
            if motion.bounceCount == 5 && fifthAt == nil { fifthAt = now }
            if let fifthAt {
                panel.alphaValue = CGFloat(max(0, 1 - (now - fifthAt) / 1.1))
                if now - fifthAt >= 1.1 {
                    check(serverSamples > 0, "no WindowServer samples")
                    print("ParticlePanel LIVE PASS: \(samples) frames, \(serverSamples) WindowServer samples, 5 rebounds, max error=\(maximumError) pt")
                    timer.invalidate()
                    panel.orderOut(nil)
                    NSApp.terminate(nil)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        NSApp.run()
    }

    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fatalError(message) }
    }
}
