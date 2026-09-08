import SwiftUI

struct MiniProgressBar: View {
    let title: String
    let percent: Double
    let resetText: String?
    let accentColor: Color

    init(
        title: String,
        percent: Double,
        resetText: String? = nil,
        accentColor: Color = .blue
    ) {
        self.title = title
        self.percent = min(max(percent, 0.0), 100.0)
        self.resetText = resetText
        self.accentColor = accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.9))

                Spacer()

                Text("\(Int(percent))%")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.usageColor(for: percent))
                    .contentTransition(.numericText())

            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .fill(Color.primary.opacity(0.08))

                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .fill(barGradient(for: percent))
                        .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(percent / 100.0))))
                }
            }
            .frame(height: 6)
            .animation(.spring(response: 0.45, dampingFraction: 0.8), value: percent)

            if let resetText = resetText, !resetText.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text(resetText)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.top, 1)
            }
        }
    }

    private func barGradient(for val: Double) -> LinearGradient {
        if val >= 90.0 {
            return LinearGradient(
                colors: [Color.red.opacity(0.85), Color.red],
                startPoint: .leading,
                endPoint: .trailing
            )
        } else if val >= 70.0 {
            return LinearGradient(
                colors: [Color.orange.opacity(0.85), Color.orange],
                startPoint: .leading,
                endPoint: .trailing
            )
        } else {
            return LinearGradient(
                colors: [accentColor.opacity(0.8), accentColor],
                startPoint: .leading,
                endPoint: .trailing
            )
        }
    }
}
