import Foundation
import CoreGraphics

/// Motion in the rectangle available to a sticker's bottom-left origin.
/// Resolve at the time of contact, then travel for the rest of the frame with
/// the new velocity. This avoids correcting an overshoot with an old velocity.
enum BounceMotion {
    static let maximumBounces = 5
    static let minimumDepartureAngle: CGFloat = 18 * .pi / 180

    struct State {
        var position: CGPoint
        var velocity: CGPoint
        var bounceCount: Int = 0
    }

    struct Rebound {
        var speedMultiplier: CGFloat
        var angleOffset: CGFloat

        static func random() -> Rebound {
            Rebound(speedMultiplier: .random(in: 0.84...0.94),
                    angleOffset: CGFloat.random(in: -9...9) * .pi / 180)
        }
    }

    static func advance(_ state: inout State, in bounds: CGRect,
                        delta: CGFloat,
                        rebound: () -> Rebound = Rebound.random) {
        guard delta > 0, bounds.width > 0, bounds.height > 0 else { return }
        let drag = CGFloat(exp(-0.008 * Double(delta)))
        state.velocity.x *= drag
        state.velocity.y *= drag
        var remaining = delta

        if state.bounceCount < maximumBounces {
            state.position.x = min(max(state.position.x, bounds.minX), bounds.maxX)
            state.position.y = min(max(state.position.y, bounds.minY), bounds.maxY)
        }

        while remaining > 0 {
            // The fifth rebound starts the fade. During it, keep moving even
            // if another edge is reached: clamping/zeroing one component makes
            // a fading sticker stick to the wall. There is no sixth rebound.
            if state.bounceCount >= maximumBounces {
                travel(&state, for: remaining)
                break
            }

            let vx = state.velocity.x
            let vy = state.velocity.y
            let tx: CGFloat = vx > 0 ? (bounds.maxX - state.position.x) / vx
                : vx < 0 ? (bounds.minX - state.position.x) / vx : .infinity
            let ty: CGFloat = vy > 0 ? (bounds.maxY - state.position.y) / vy
                : vy < 0 ? (bounds.minY - state.position.y) / vy : .infinity
            let contactTime = max(0, min(tx, ty))
            if contactTime > remaining {
                travel(&state, for: remaining)
                break
            }

            travel(&state, for: contactTime)
            remaining = max(0, remaining - contactTime)
            let hitX = abs(tx - contactTime) <= 1e-9
            let hitY = abs(ty - contactTime) <= 1e-9
            if hitX { state.position.x = vx > 0 ? bounds.maxX : bounds.minX }
            if hitY { state.position.y = vy > 0 ? bounds.maxY : bounds.minY }

            let reflectedX = hitX ? -vx : vx
            let reflectedY = hitY ? -vy : vy
            let variation = rebound()
            let speed = hypot(vx, vy) * variation.speedMultiplier
            let angle = atan2(reflectedY, reflectedX) + variation.angleOffset
            var nextX = speed * cos(angle)
            var nextY = speed * sin(angle)
            let minimumNormal = speed * sin(minimumDepartureAngle)

            // Preserve random deflection, but always leave the contacted wall
            // by at least 18 degrees instead of travelling almost along it.
            if hitX && hitY {
                let magnitudeX = min(max(abs(nextX), minimumNormal),
                                     speed * cos(minimumDepartureAngle))
                nextX = vx > 0 ? -magnitudeX : magnitudeX
                let magnitudeY = sqrt(max(0, speed * speed - magnitudeX * magnitudeX))
                nextY = vy > 0 ? -magnitudeY : magnitudeY
            } else if hitX {
                let magnitudeX = max(abs(nextX), minimumNormal)
                nextX = vx > 0 ? -magnitudeX : magnitudeX
                let magnitudeY = sqrt(max(0, speed * speed - magnitudeX * magnitudeX))
                nextY = nextY < 0 ? -magnitudeY : magnitudeY
            } else if hitY {
                let magnitudeY = max(abs(nextY), minimumNormal)
                nextY = vy > 0 ? -magnitudeY : magnitudeY
                let magnitudeX = sqrt(max(0, speed * speed - magnitudeY * magnitudeY))
                nextX = nextX < 0 ? -magnitudeX : magnitudeX
            }
            state.velocity = CGPoint(x: nextX, y: nextY)
            state.bounceCount += 1
        }
    }

    private static func travel(_ state: inout State, for delta: CGFloat) {
        state.position.x += state.velocity.x * delta
        state.position.y += state.velocity.y * delta
    }
}
