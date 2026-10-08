import Foundation
import CoreGraphics

@main
struct BounceMotionHarness {
    static func main() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let normalRatio = sin(BounceMotion.minimumDepartureAngle)
        let fixed = BounceMotion.Rebound(speedMultiplier: 0.9, angleOffset: 0)

        // A nearly tangent incoming trajectory, including deflections that
        // previously cancelled or reversed its tiny wall-normal component.
        for offset: CGFloat in [-9, 0, 9] {
            for wall in 0..<4 {
                let positions = [CGPoint(x: 0, y: 400), CGPoint(x: 1000, y: 400),
                                 CGPoint(x: 500, y: 0), CGPoint(x: 500, y: 800)]
                let velocities = [CGPoint(x: -1, y: 400), CGPoint(x: 1, y: 400),
                                  CGPoint(x: 400, y: -1), CGPoint(x: 400, y: 1)]
                var state = BounceMotion.State(position: positions[wall], velocity: velocities[wall])
                BounceMotion.advance(&state, in: bounds, delta: 0.05) {
                    .init(speedMultiplier: 0.9, angleOffset: offset * .pi / 180)
                }
                check(state.bounceCount == 1, "one contact on wall \(wall)")
                let speed = hypot(state.velocity.x, state.velocity.y)
                let normal = wall < 2 ? abs(state.velocity.x) : abs(state.velocity.y)
                check(normal / speed >= normalRatio - 1e-10, "clear departure from wall \(wall)")
                check(state.position.x > 0 && state.position.x < 1000 &&
                      state.position.y > 0 && state.position.y < 800,
                      "leaves wall immediately within the same frame")
                check(abs(speed / hypot(1, 400) - 0.9 * exp(-0.008 * 0.05)) < 1e-10,
                      "angle correction preserves rebound speed")
            }
        }

        // Travel to contact first, then spend the remaining time at the slower
        // reflected velocity. Overshoot must not be reflected at the old speed.
        var timed = BounceMotion.State(position: CGPoint(x: 5, y: 400),
                                       velocity: CGPoint(x: -500, y: 200))
        BounceMotion.advance(&timed, in: bounds, delta: 0.05) { fixed }
        check(timed.bounceCount == 1 && abs(timed.position.x - 17.9910018) < 0.00001,
              "contact time consumes the frame correctly")

        // Exact corners count once, and both components point away from them.
        for corner in 0..<4 {
            let right = corner & 1 != 0
            let top = corner & 2 != 0
            var state = BounceMotion.State(position: CGPoint(x: right ? 995 : 5, y: top ? 795 : 5),
                                           velocity: CGPoint(x: right ? 100 : -100, y: top ? 100 : -100))
            BounceMotion.advance(&state, in: bounds, delta: 0.1) { fixed }
            check(state.bounceCount == 1, "corner counts as one rebound")
            check((right ? state.velocity.x < 0 : state.velocity.x > 0) &&
                  (top ? state.velocity.y < 0 : state.velocity.y > 0), "corner rebounds inward")
        }

        // Resolve two separate walls in one delayed animation frame.
        var nearby = BounceMotion.State(position: CGPoint(x: 1, y: 1),
                                        velocity: CGPoint(x: -500, y: -100))
        BounceMotion.advance(&nearby, in: bounds, delta: 0.05) { fixed }
        check(nearby.bounceCount == 2 && nearby.position.x > 0 && nearby.position.y > 0,
              "near-corner contacts resolved within the frame")
        var fast = BounceMotion.State(position: CGPoint(x: 50, y: 50),
                                      velocity: CGPoint(x: 50000, y: 0))
        BounceMotion.advance(&fast, in: CGRect(x: 0, y: 0, width: 100, height: 100), delta: 0.05) { fixed }
        check(fast.bounceCount == 5, "multiple contacts stop at the fifth rebound")

        // Fading sprites must keep moving rather than having their normal
        // component zeroed when reaching another wall.
        var fading = BounceMotion.State(position: CGPoint(x: 999, y: 400),
                                        velocity: CGPoint(x: 400, y: 100), bounceCount: 5)
        BounceMotion.advance(&fading, in: bounds, delta: 0.05) { fixed }
        check(fading.bounceCount == 5 && fading.velocity.x > 399 && fading.position.x > 1018,
              "fading motion crosses the edge without sliding or a sixth rebound")

        var generator = SeededRandom()
        let screens = [CGRect(x: 0, y: 0, width: 1392, height: 878),
                       CGRect(x: -1920, y: 100, width: 1842, height: 1002),
                       CGRect(x: 200, y: -400, width: 242, height: 162)]
        var trajectories = 0
        for screen in screens {
            for _ in 0..<800 {
                let angle = (24 + 52 * generator.unit()) * .pi / 180
                let speed = (480 + 660 * generator.unit()) * (0.94 + 0.12 * generator.unit())
                var state = BounceMotion.State(position: CGPoint(x: screen.maxX - 1, y: screen.minY + 1),
                                               velocity: CGPoint(x: -speed * cos(angle), y: speed * sin(angle)))
                for frame in 0..<12000 {
                    let oldCount = state.bounceCount
                    BounceMotion.advance(&state, in: screen, delta: frame % 29 == 0 ? 0.05 : 1 / 60) {
                        .init(speedMultiplier: 0.84 + 0.1 * generator.unit(),
                              angleOffset: (-9 + 18 * generator.unit()) * .pi / 180)
                    }
                    check(state.bounceCount >= oldCount && state.bounceCount <= 5, "bounded bounce count")
                    if state.bounceCount == 5 { break }
                    check(state.position.x >= screen.minX - 1e-8 && state.position.x <= screen.maxX + 1e-8 &&
                          state.position.y >= screen.minY - 1e-8 && state.position.y <= screen.maxY + 1e-8,
                          "active trajectory stays inside the display")
                }
                check(state.bounceCount == 5, "random trajectory reaches fifth rebound")
                trajectories += 1
            }
        }
        print("BounceMotion PASS: 6 scenario groups, \(trajectories) seeded trajectories")
    }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    struct SeededRandom {
        private var value: UInt64 = 0x43515020260930
        mutating func unit() -> CGFloat {
            value = value &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(value >> 11) / CGFloat(UInt64(1) << 53)
        }
    }
}
