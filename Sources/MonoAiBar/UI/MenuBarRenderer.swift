import AppKit

@MainActor
final class MenuBarRenderer {
    static let shared = MenuBarRenderer()

    private enum Metrics {
        static let height: CGFloat = 22.0
        static let columnGap: CGFloat = 7.0
        static let padding: CGFloat = 2.0
        static let minimumColumnWidth: CGFloat = 26.0
        static let iconBoundingBox = CGSize(width: 12.0, height: 10.5)
        static let alertDotDiameter: CGFloat = 3.0
    }

    // NSFont and an immutable NSParagraphStyle are read-only value-like objects, safe to touch
    // from the drawing handler that AppKit invokes while rasterising the image.
    nonisolated(unsafe) private static let labelFont = NSFont.systemFont(ofSize: 8.0, weight: .bold)
    nonisolated(unsafe) private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
    nonisolated(unsafe) private static let inlineLabelFont = NSFont.monospacedSystemFont(ofSize: 10.0, weight: .medium)

    nonisolated(unsafe) private static let centered: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        return style
    }()

    /// One provider's slot in the status item. The brand icon is boxed so the `@Sendable` drawing
    /// handler can carry it; the image is a template drawn only from AppKit's own rasterisation
    /// callback.
    private struct Column: @unchecked Sendable {
        let label: String
        let value: String
        let icon: NSImage
        let isAlerting: Bool
        let width: CGFloat
    }

    private var cacheKey: String?
    private var cachedImage: NSImage?

    private init() {}

    /// Usage strings are passed in rather than pulled from the manager so the cache key covers
    /// exactly what gets drawn, and an unrelated published change cannot force a redraw.
    func image(
        mode: MenuBarDisplayMode,
        providers: [ProviderType],
        usage: [String],
        alerts: [Bool] = []
    ) -> NSImage {
        let active = providers.isEmpty ? [.claude, .antigravity] : providers
        let values = usage.count == active.count ? usage : active.map { _ in "--%" }
        let alerting = alerts.count == active.count ? alerts : active.map { _ in false }

        let key = "\(mode.rawValue)|" + zip(active, zip(values, alerting))
            .map { "\($0.id)=\($1.0)\($1.1 ? "!" : "")" }
            .joined(separator: ",")
        if key == cacheKey, let cachedImage {
            return cachedImage
        }

        let columns = self.columns(mode: mode, providers: active, values: values, alerting: alerting)
        let image = switch mode {
        case .textAbove: stackedImage(columns: columns)
        case .inlineText: inlineImage(columns: columns)
        case .icons: iconImage(columns: columns)
        }

        cacheKey = key
        cachedImage = image
        return image
    }

    private func columns(
        mode: MenuBarDisplayMode,
        providers: [ProviderType],
        values: [String],
        alerting: [Bool]
    ) -> [Column] {
        zip(providers, zip(values, alerting)).map { provider, state in
            let (value, isAlerting) = state
            let label = provider.shortCode.uppercased()
            let valueWidth = value.size(withAttributes: [.font: Self.valueFont]).width

            let contentWidth: CGFloat = switch mode {
            case .textAbove:
                max(label.size(withAttributes: [.font: Self.labelFont]).width, valueWidth)
            case .inlineText:
                label.size(withAttributes: [.font: Self.inlineLabelFont]).width + 3.0 + valueWidth
            case .icons:
                max(Metrics.iconBoundingBox.width, valueWidth)
            }

            let alertAllowance = isAlerting ? Metrics.alertDotDiameter + 2.0 : 0.0
            return Column(
                label: label,
                value: value,
                icon: provider.brandIcon,
                isAlerting: isAlerting,
                width: max(Metrics.minimumColumnWidth, contentWidth + 6.0 + alertAllowance)
            )
        }
    }

    private func stackedImage(columns: [Column]) -> NSImage {
        template(width: totalWidth(of: columns)) { _ in
            Self.layOut(columns) { column, x in
                Self.draw(
                    column.label,
                    in: NSRect(x: x, y: 11.8, width: column.width, height: 9.0),
                    font: Self.labelFont
                )
                Self.draw(
                    column.value,
                    in: NSRect(x: x, y: 1.0, width: column.width, height: 11.0),
                    font: Self.valueFont
                )
            }
        }
    }

    private func inlineImage(columns: [Column]) -> NSImage {
        template(width: totalWidth(of: columns)) { _ in
            Self.layOut(columns) { column, x in
                let labelWidth = column.label.size(withAttributes: [.font: Self.inlineLabelFont]).width
                let valueWidth = column.value.size(withAttributes: [.font: Self.valueFont]).width
                let contentWidth = labelWidth + 3.0 + valueWidth
                let leading = x + (column.width - contentWidth) / 2.0

                Self.draw(
                    column.label,
                    in: NSRect(x: leading, y: 5.8, width: labelWidth, height: 11.0),
                    font: Self.inlineLabelFont
                )
                Self.draw(
                    column.value,
                    in: NSRect(x: leading + labelWidth + 3.0, y: 5.4, width: valueWidth, height: 11.0),
                    font: Self.valueFont
                )
            }
        }
    }

    private func iconImage(columns: [Column]) -> NSImage {
        template(width: totalWidth(of: columns)) { _ in
            Self.layOut(columns) { column, x in
                let native = column.icon.size
                let scale = min(
                    Metrics.iconBoundingBox.width / max(1.0, native.width),
                    Metrics.iconBoundingBox.height / max(1.0, native.height)
                )
                let iconWidth = round(native.width * scale * 2.0) / 2.0
                let iconHeight = round(native.height * scale * 2.0) / 2.0

                column.icon.draw(in: NSRect(
                    x: round((x + (column.width - iconWidth) / 2.0) * 2.0) / 2.0,
                    y: round((10.8 + (Metrics.iconBoundingBox.height - iconHeight) / 2.0) * 2.0) / 2.0,
                    width: iconWidth,
                    height: iconHeight
                ))
                Self.draw(
                    column.value,
                    in: NSRect(x: x, y: 0.6, width: column.width, height: 10.8),
                    font: Self.valueFont
                )
            }
        }
    }

    private func totalWidth(of columns: [Column]) -> CGFloat {
        let gaps = Metrics.columnGap * CGFloat(max(0, columns.count - 1))
        return max(24.0, Metrics.padding * 2.0 + columns.reduce(0.0) { $0 + $1.width } + gaps)
    }

    /// Walks the columns left to right and stamps the alert dot, so each mode only has to describe
    /// what goes inside its own slot.
    nonisolated private static func layOut(_ columns: [Column], body: (Column, CGFloat) -> Void) {
        var x = Metrics.padding
        for column in columns {
            body(column, x)
            if column.isAlerting {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(
                    x: x + column.width - Metrics.alertDotDiameter - 1.0,
                    y: Metrics.height - Metrics.alertDotDiameter - 1.5,
                    width: Metrics.alertDotDiameter,
                    height: Metrics.alertDotDiameter
                )).fill()
            }
            x += column.width + Metrics.columnGap
        }
    }

    nonisolated private func template(width: CGFloat, draw: @escaping @Sendable (NSRect) -> Void) -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: Metrics.height), flipped: false) { rect in
            draw(rect)
            return true
        }
        image.isTemplate = true
        return image
    }

    nonisolated private static func draw(_ text: String, in rect: NSRect, font: NSFont) {
        NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.black,
            .paragraphStyle: centered
        ]).draw(with: rect, options: [.usesLineFragmentOrigin])
    }
}
