import SwiftUI

/// The single place a provider glyph becomes a SwiftUI view, so every surface renders it at a
/// declared size instead of whatever intrinsic size the template image happens to carry.
struct BrandIcon: View {
    let provider: ProviderType
    var size: CGFloat = 12.0
    var tinted: Bool = true

    var body: some View {
        Image(nsImage: provider.brandIcon)
            .resizable()
            .renderingMode(.template)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .foregroundStyle(tinted ? AnyShapeStyle(provider.accentColor) : AnyShapeStyle(.primary))
    }
}
