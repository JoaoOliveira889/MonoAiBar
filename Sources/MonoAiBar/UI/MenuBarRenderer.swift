import AppKit

@MainActor
final class MenuBarRenderer {
    static let shared = MenuBarRenderer()

    private enum Metrics {
        static let height: CGFloat = 22.0
        static let columnGap: CGFloat = 11.0
        static let padding: CGFloat = 3.0
        static let minimumColumnWidth: CGFloat = 28.0
        static let maxIconBoundingBox = CGSize(width: 13.0, height: 11.0)
    }

    // NSFont and an immutable NSParagraphStyle are read-only value-like objects, safe to touch
    // from the drawing handler that AppKit invokes while rasterising the image.
    nonisolated(unsafe) private static let labelFont = NSFont.systemFont(ofSize: 8.0, weight: .bold)
    nonisolated(unsafe) private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
    nonisolated(unsafe) private static let inlineFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold)

    nonisolated(unsafe) private static let centered: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        return style
    }()

    /// Boxes the brand icon so the `@Sendable` drawing handler can carry it. The image is a
    /// template drawn only from AppKit's own rasterisation callback.
    private struct IconColumn: @unchecked Sendable {
        let icon: NSImage
        let value: String
        let width: CGFloat
    }

    private var cacheKey: String?
    private var cachedImage: NSImage?

    private init() {}

    /// Usage strings are passed in rather than pulled from the manager so the cache key covers
    /// exactly what gets drawn, and an unrelated published change cannot force a redraw.
    func image(mode: MenuBarDisplayMode, providers: [ProviderType], usage: [String]) -> NSImage {
        let active = providers.isEmpty ? [.claude, .antigravity] : providers
        let values = usage.count == active.count ? usage : active.map { _ in "--%" }

        let key = "\(mode.rawValue)|" + zip(active, values).map { "\($0.id)=\($1)" }.joined(separator: ",")
        if key == cacheKey, let cachedImage {
            return cachedImage
        }

        let image = switch mode {
        case .textAbove: stackedImage(providers: active, values: values)
        case .inlineText: inlineImage(providers: active, values: values)
        case .icons: iconImage(providers: active, values: values)
        }

        cacheKey = key
        cachedImage = image
        return image
    }

    private func stackedImage(providers: [ProviderType], values: [String]) -> NSImage {
        let columns = zip(providers, values).map { provider, value -> (label: String, value: String, width: CGFloat) in
            let label = provider.shortCode.uppercased()
            let labelWidth = label.size(withAttributes: [.font: Self.labelFont]).width
            let valueWidth = value.size(withAttributes: [.font: Self.valueFont]).width
            return (label, value, max(Metrics.minimumColumnWidth, max(labelWidth, valueWidth) + 6.0))
        }

        return template(width: totalWidth(of: columns.map(\.width))) { _ in
            var x = Metrics.padding
            for column in columns {
                Self.draw(
                    column.label,
                    in: NSRect(x: x, y: 11.5, width: column.width, height: 9.0),
                    font: Self.labelFont
                )
                Self.draw(
                    column.value,
                    in: NSRect(x: x, y: 1.0, width: column.width, height: 11.0),
                    font: Self.valueFont
                )
                x += column.width + Metrics.columnGap
            }
        }
    }

    private func inlineImage(providers: [ProviderType], values: [String]) -> NSImage {
        let text = zip(providers, values)
            .map { "\($0.shortCode) \($1)" }
            .joined(separator: "  ")
        let size = text.size(withAttributes: [.font: Self.inlineFont])
        let padding: CGFloat = 4.0

        return template(width: size.width + padding * 2.0) { _ in
            text.draw(
                at: NSPoint(x: padding, y: (Metrics.height - size.height) / 2.0 + 0.5),
                withAttributes: [.font: Self.inlineFont, .foregroundColor: NSColor.black]
            )
        }
    }

    private func iconImage(providers: [ProviderType], values: [String]) -> NSImage {
        let columns = zip(providers, values).map { provider, value in
            let valueWidth = value.size(withAttributes: [.font: Self.valueFont]).width
            return IconColumn(
                icon: provider.brandIcon,
                value: value,
                width: max(Metrics.minimumColumnWidth, max(Metrics.maxIconBoundingBox.width, valueWidth) + 6.0)
            )
        }

        return template(width: totalWidth(of: columns.map(\.width))) { _ in
            var x = Metrics.padding
            for column in columns {
                let native = column.icon.size
                let scale = min(
                    Metrics.maxIconBoundingBox.width / max(1.0, native.width),
                    Metrics.maxIconBoundingBox.height / max(1.0, native.height)
                )
                let iconW = round(native.width * scale * 2.0) / 2.0
                let iconH = round(native.height * scale * 2.0) / 2.0
                let iconX = round((x + (column.width - iconW) / 2.0) * 2.0) / 2.0
                let iconY = round((10.5 + (Metrics.maxIconBoundingBox.height - iconH) / 2.0) * 2.0) / 2.0

                column.icon.draw(in: NSRect(
                    x: iconX,
                    y: iconY,
                    width: iconW,
                    height: iconH
                ))
                Self.draw(
                    column.value,
                    in: NSRect(x: x, y: 0.8, width: column.width, height: 10.8),
                    font: Self.valueFont
                )
                x += column.width + Metrics.columnGap
            }
        }
    }

    private func totalWidth(of columnWidths: [CGFloat]) -> CGFloat {
        let gaps = Metrics.columnGap * CGFloat(max(0, columnWidths.count - 1))
        return max(24.0, Metrics.padding * 2.0 + columnWidths.reduce(0, +) + gaps)
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
