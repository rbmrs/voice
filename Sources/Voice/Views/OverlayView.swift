import SwiftUI

struct OverlayView: View {
    static let preferredWidth: CGFloat = 392

    let state: DictationState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: state.menuSymbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(state.overlayTitle)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(state.overlayDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(state.overlayDetailLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: Self.preferredWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.white.opacity(0.16))
        )
    }

    private var tint: Color {
        switch state {
        case .idle:
            .secondary
        case .listening:
            .red
        case .transcribing, .refining, .inserting:
            .blue
        case .completed:
            .green
        case .error:
            .orange
        }
    }
}
