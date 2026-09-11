import AppKit

/// Drawn with `NSImage(size:flipped:drawingHandler:)` rather than `lockFocus`, so each icon is
/// re-rasterised at whatever backing scale the current display uses instead of being baked at the
/// scale that happened to be active when the constant was first touched.
///
/// Every glyph is a template: the menu bar inverts it for light and dark, and SwiftUI tints it
/// with the provider accent colour inside the panel.
@MainActor
enum OfficialBrandIcons {
    /// Anthropic's Claude mark: a radial burst of round-tipped rays of alternating length.
    static let claude = template(width: 14, height: 14) { context in
        let center = CGPoint(x: 7.0, y: 7.0)
        let rayCount = 12

        context.setStrokeColor(NSColor.black.cgColor)
        context.setLineCap(.round)

        for ray in 0..<rayCount {
            let angle = (CGFloat(ray) / CGFloat(rayCount)) * 2.0 * .pi + .pi / 12.0
            let isLong = ray.isMultiple(of: 2)

            context.setLineWidth(isLong ? 1.15 : 1.0)
            context.move(to: CGPoint(
                x: center.x,
                y: center.y
            ))
            context.addLine(to: CGPoint(
                x: center.x + (isLong ? 6.4 : 5.3) * cos(angle),
                y: center.y + (isLong ? 6.4 : 5.3) * sin(angle)
            ))
            context.strokePath()
        }
    }

    /// Google Antigravity's mark: a tapered arch forming an "A", hollowed by a rounded valley.
    static let antigravity = template(width: 14, height: 13) { context in
        let path = CGMutablePath()

        // Outer arch, from the left foot over the apex and down to the right foot.
        path.move(to: CGPoint(x: 1.5, y: 1.9))
        path.addCurve(
            to: CGPoint(x: 7.0, y: 12.1),
            control1: CGPoint(x: 2.6, y: 6.2),
            control2: CGPoint(x: 4.3, y: 12.1)
        )
        path.addCurve(
            to: CGPoint(x: 12.5, y: 1.9),
            control1: CGPoint(x: 9.7, y: 12.1),
            control2: CGPoint(x: 11.4, y: 6.2)
        )

        // Rounded right foot.
        path.addQuadCurve(
            to: CGPoint(x: 10.6, y: 1.9),
            control: CGPoint(x: 11.8, y: 0.5)
        )

        // Inner edge, right leg up into the valley and back down the left leg.
        path.addCurve(
            to: CGPoint(x: 7.0, y: 5.9),
            control1: CGPoint(x: 10.0, y: 4.0),
            control2: CGPoint(x: 8.7, y: 5.9)
        )
        path.addCurve(
            to: CGPoint(x: 3.4, y: 1.9),
            control1: CGPoint(x: 5.3, y: 5.9),
            control2: CGPoint(x: 4.0, y: 4.0)
        )

        // Rounded left foot.
        path.addQuadCurve(
            to: CGPoint(x: 1.5, y: 1.9),
            control: CGPoint(x: 2.2, y: 0.5)
        )
        path.closeSubpath()

        context.setFillColor(NSColor.black.cgColor)
        context.addPath(path)
        context.fillPath()
    }

    /// OpenAI's mark, which Codex ships under: a six-fold knot of thin interlocking strands.
    static let codex = template(width: 13, height: 13) { context in
        let center = CGPoint(x: 6.5, y: 6.5)
        let radius: CGFloat = 5.3

        context.setStrokeColor(NSColor.black.cgColor)
        context.setLineWidth(0.95)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        func point(_ angle: CGFloat, _ scale: CGFloat) -> CGPoint {
            CGPoint(x: center.x + radius * scale * cos(angle), y: center.y + radius * scale * sin(angle))
        }

        // Six petals leave the core, round off at the rim, and return: the blossom shape that
        // reads correctly even at menu bar size.
        for strand in 0..<6 {
            let angle = CGFloat(strand) * .pi / 3.0
            let path = CGMutablePath()
            path.move(to: point(angle - 0.30, 0.22))
            path.addCurve(
                to: point(angle, 0.98),
                control1: point(angle - 0.62, 0.72),
                control2: point(angle - 0.40, 1.02)
            )
            path.addCurve(
                to: point(angle + 0.30, 0.22),
                control1: point(angle + 0.40, 1.02),
                control2: point(angle + 0.62, 0.72)
            )
            context.addPath(path)
            context.strokePath()
        }
    }

    private static func template(
        width: CGFloat,
        height: CGFloat,
        draw: @escaping @Sendable (CGContext) -> Void
    ) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(context)
            return true
        }
        image.isTemplate = true
        return image
    }
}
