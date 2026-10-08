import AppKit

@main
@MainActor
struct RadialWheelGeometryHarness {
    static func main() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let pet = NSRect(x: 1040, y: 0, width: 400, height: 400)

        let menuFrame = RadialWheel.placement(near: pet, in: screen)
        check(menuFrame.size == NSSize(width: 420, height: 420), "ten-button wheel size")
        check(contains(screen, menuFrame), "menu wheel stays on screen")
        check(pet.intersection(menuFrame).width > 0 &&
              pet.intersection(menuFrame).height > 0, "menu wheel overlays pet")

        let click = NSPoint(x: 1080, y: 320)
        let clickedFrame = RadialWheel.placement(near: pet, in: screen, at: click)
        check(clickedFrame.midX == click.x && clickedFrame.midY == click.y,
              "click wheel centers on click when space permits")
        check(pet.intersects(clickedFrame), "click wheel overlays pet")

        let edgeFrame = RadialWheel.placement(near: pet, in: screen,
                                               at: NSPoint(x: 1430, y: 10))
        check(contains(screen, edgeFrame), "edge click wheel stays on screen")
        check(pet.intersects(edgeFrame), "edge click wheel still overlays pet")

        let bottomDockVisibleFrame = NSRect(x: 0, y: 80, width: 1440, height: 790)
        let usable = RadialWheel.usableScreenFrame(screenFrame: screen,
                                                    visibleFrame: bottomDockVisibleFrame)
        let dockFrame = RadialWheel.placement(near: pet, in: usable,
                                               at: NSPoint(x: 1430, y: 10))
        check(usable == bottomDockVisibleFrame, "uses valid visible frame")
        check(contains(bottomDockVisibleFrame, dockFrame),
              "wheel clears bottom Dock and menu bar")
        check(pet.intersects(dockFrame), "Dock clamp still overlays pet")
        check(RadialWheel.usableScreenFrame(screenFrame: screen,
                                            visibleFrame: .zero) == screen,
              "empty visible frame falls back to screen")
        check(RadialWheel.usableScreenFrame(
                screenFrame: screen,
                visibleFrame: NSRect(x: 0, y: 80, width: 230, height: 790)) == screen,
              "too-small visible frame falls back to screen")

        let otherScreen = NSRect(x: -1680, y: 100, width: 1680, height: 1050)
        let otherPet = NSRect(x: -400, y: 100, width: 400, height: 400)
        let otherFrame = RadialWheel.placement(near: otherPet, in: otherScreen,
                                                at: NSPoint(x: -5, y: 120))
        check(contains(otherScreen, otherFrame), "negative-origin screen clamp")
        check(otherPet.intersects(otherFrame), "negative-origin wheel overlays pet")

        let smallScreen = NSRect(x: 100, y: 200, width: 210, height: 180)
        let smallFrame = RadialWheel.placement(near: smallScreen, in: smallScreen)
        check(contains(smallScreen, smallFrame), "small screen wheel fits")
        check(smallFrame.width == 168 && smallFrame.height == 168,
              "small screen scales wheel")

        check(RadialWheel.Action.allCases.count == 10,
              "all ten former menu actions are present")
        for side: CGFloat in [168, 420] {
            let bounds = NSRect(x: 0, y: 0, width: side, height: side)
            let buttonRadius = RadialWheel.buttonRadius(in: bounds)
            let hubRadius = RadialWheel.hubRadius(in: bounds)
            let centers = RadialWheel.Action.allCases.map {
                RadialWheel.buttonCenter(for: $0, in: bounds)
            }
            for center in centers {
                check(center.x - buttonRadius >= bounds.minX &&
                      center.x + buttonRadius <= bounds.maxX &&
                      center.y - buttonRadius >= bounds.minY &&
                      center.y + buttonRadius <= bounds.maxY,
                      "all ten controls fit in wheel panel")
                check(hypot(center.x - bounds.midX, center.y - bounds.midY) >
                      buttonRadius + hubRadius,
                      "each button clears the center close control")
            }
            for first in centers.indices {
                for second in centers.indices where second > first {
                    check(hypot(centers[first].x - centers[second].x,
                                centers[first].y - centers[second].y) >
                          2 * buttonRadius,
                          "button hit areas do not overlap")
                }
            }
            let arcStart = RadialWheel.buttonCenter(for: .arc, in: bounds,
                                                     progress: 0.15)
            let arcEnd = RadialWheel.buttonCenter(for: .arc, in: bounds,
                                                   progress: 1)
            check(hypot(arcEnd.x - bounds.midX, arcEnd.y - bounds.midY) >
                  hypot(arcStart.x - bounds.midX, arcStart.y - bounds.midY),
                  "button centers unfold outward")
        }

        print("RadialWheelGeometry PASS")
    }

    private static func contains(_ outer: NSRect, _ inner: NSRect) -> Bool {
        inner.minX >= outer.minX && inner.maxX <= outer.maxX &&
        inner.minY >= outer.minY && inner.maxY <= outer.maxY
    }

    private static func check(_ condition: Bool, _ message: String) {
        guard condition else { fatalError("RadialWheelGeometry: \(message)") }
    }
}
