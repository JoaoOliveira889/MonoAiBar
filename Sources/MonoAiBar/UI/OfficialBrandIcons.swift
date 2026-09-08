import AppKit

/// Drawn with `NSImage(size:flipped:drawingHandler:)` rather than `lockFocus`, so each icon is
/// re-rasterised at whatever backing scale the current display uses instead of being baked at the
/// scale that happened to be active when the constant was first touched.
@MainActor
enum OfficialBrandIcons {
    static let claude = template(width: 15, height: 13) { context in
        context.setFillColor(NSColor.black.cgColor)
        context.setStrokeColor(NSColor.black.cgColor)

        // Body: balanced squircle with good vertical proportion
        let body = CGRect(x: 2.5, y: 2.6, width: 10.0, height: 6.2)
        context.addPath(CGPath(roundedRect: body, cornerWidth: 2.2, cornerHeight: 2.2, transform: nil))
        context.fillPath()

        // Claws
        for claw in [
            [(3.5, 7.0), (1.2, 8.5), (0.8, 11.8), (2.2, 9.8), (3.8, 12.2), (3.2, 8.8)],
            [(11.5, 7.0), (13.8, 8.5), (14.2, 11.8), (12.8, 9.8), (11.2, 12.2), (11.8, 8.8)]
        ] {
            let path = CGMutablePath()
            path.addLines(between: claw.map { CGPoint(x: $0.0, y: $0.1) })
            path.closeSubpath()
            context.addPath(path)
            context.fillPath()
        }

        // Legs: 4 legs nicely spread
        context.setLineWidth(1.3)
        context.setLineCap(.round)
        for leg in [((4.0, 2.6), (3.0, 0.6)), ((6.0, 2.6), (5.5, 0.4)),
                    ((9.0, 2.6), (9.5, 0.4)), ((11.0, 2.6), (12.0, 0.6))] {
            context.move(to: CGPoint(x: leg.0.0, y: leg.0.1))
            context.addLine(to: CGPoint(x: leg.1.0, y: leg.1.1))
            context.strokePath()
        }

        // Eyes: clear cutouts
        context.setBlendMode(.clear)
        context.fill(CGRect(x: 4.5, y: 5.0, width: 2.0, height: 2.2))
        context.fill(CGRect(x: 8.5, y: 5.0, width: 2.0, height: 2.2))
    }

    static let antigravity = template(width: 13, height: 13) { context in
        let center = CGPoint(x: 6.5, y: 6.5)
        let radius = CGSize(width: 5.5, height: 5.5)
        let control = CGSize(width: 1.0, height: 1.0)

        let path = CGMutablePath()
        path.move(to: CGPoint(x: center.x, y: center.y + radius.height))
        path.addQuadCurve(
            to: CGPoint(x: center.x + radius.width, y: center.y),
            control: CGPoint(x: center.x + control.width, y: center.y + control.height)
        )
        path.addQuadCurve(
            to: CGPoint(x: center.x, y: center.y - radius.height),
            control: CGPoint(x: center.x + control.width, y: center.y - control.height)
        )
        path.addQuadCurve(
            to: CGPoint(x: center.x - radius.width, y: center.y),
            control: CGPoint(x: center.x - control.width, y: center.y - control.height)
        )
        path.addQuadCurve(
            to: CGPoint(x: center.x, y: center.y + radius.height),
            control: CGPoint(x: center.x - control.width, y: center.y + control.height)
        )
        path.closeSubpath()

        context.addPath(path)
        context.setFillColor(NSColor.black.cgColor)
        context.fillPath()
    }

    static let codex = template(width: 13, height: 13) { context in
        let center = CGPoint(x: 6.5, y: 6.5)
        let radius: CGFloat = 5.2

        context.setStrokeColor(NSColor.black.cgColor)
        context.setLineWidth(1.3)
        context.setLineCap(.round)

        for spoke in 0..<6 {
            let angle = CGFloat(spoke) * .pi / 3.0
            let path = CGMutablePath()
            path.move(to: CGPoint(
                x: center.x + radius * 0.35 * cos(angle),
                y: center.y + radius * 0.35 * sin(angle)
            ))
            path.addQuadCurve(
                to: CGPoint(
                    x: center.x + radius * 0.85 * cos(angle + 1.25),
                    y: center.y + radius * 0.85 * sin(angle + 1.25)
                ),
                control: CGPoint(
                    x: center.x + radius * cos(angle + 0.6),
                    y: center.y + radius * sin(angle + 0.6)
                )
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
