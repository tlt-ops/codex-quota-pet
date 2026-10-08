import AppKit

/// AppKit normally pushes a borderless panel down below the menu bar. Particle
/// motion uses the full display, so that correction would pin a sprite while
/// its simulated position keeps moving toward the actual screen edge.
final class ParticlePanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
