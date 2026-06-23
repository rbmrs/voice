import SwiftUI

struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let content: Content

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.largeTitle.weight(.semibold))

                    if let subtitle {
                        Text(subtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(28)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct SettingsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(
        title: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)

            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.75), lineWidth: 1)
        )
    }
}

struct SettingsRow<Content: View>: View {
    let title: String
    var labelWidth: CGFloat = 150
    @ViewBuilder let content: Content

    init(
        title: String,
        labelWidth: CGFloat = 150,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.labelWidth = labelWidth
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(title)
                .frame(width: labelWidth, alignment: .leading)

            content
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(minHeight: 28)
        .frame(maxWidth: .infinity)
    }
}

struct SettingsRowDivider: View {
    var body: some View {
        Divider()
            .opacity(0.7)
    }
}

struct TrailingControlColumn<Content: View>: View {
    let width: CGFloat
    @ViewBuilder let content: Content

    init(
        width: CGFloat,
        @ViewBuilder content: () -> Content
    ) {
        self.width = width
        self.content = content()
    }

    var body: some View {
        content
            .fixedSize(horizontal: true, vertical: false)
            .frame(width: width, alignment: .trailing)
    }
}

struct SettingsSectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.title3.weight(.semibold))
    }
}

struct SettingsProblemRow<Actions: View>: View {
    let validation: PathValidation
    let message: String
    @ViewBuilder let actions: Actions

    init(
        validation: PathValidation,
        message: String? = nil,
        @ViewBuilder actions: () -> Actions
    ) {
        self.validation = validation
        self.message = message ?? validation.message
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Label(message, systemImage: iconName)
                .font(.callout)
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 12)

            actions
        }
    }

    private var tint: Color {
        switch validation.status {
        case .valid:
            .green
        case .warning:
            .orange
        case .invalid:
            .red
        }
    }

    private var iconName: String {
        switch validation.status {
        case .valid:
            "checkmark.circle.fill"
        case .warning:
            "exclamationmark.triangle.fill"
        case .invalid:
            "xmark.circle.fill"
        }
    }
}

extension PathValidation {
    var needsAttention: Bool {
        switch status {
        case .valid:
            false
        case .warning, .invalid:
            true
        }
    }
}
