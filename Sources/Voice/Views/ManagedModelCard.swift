import SwiftUI

struct ManagedModelGrid: View {
    let models: [ManagedModelDescriptor]
    let activePath: String
    var featuredModelIDs: [String] = []
    var collapsedLimit: Int?
    @ObservedObject var settings: AppSettings
    @ObservedObject var modelLibrary: ModelLibrary

    @State private var showsAllModels = false

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                if let customActiveURL {
                    CustomActiveModelCard(url: customActiveURL)
                }

                ForEach(visibleModels) { descriptor in
                    let isInstalled = modelLibrary.isInstalled(descriptor)

                    ManagedModelCard(
                        descriptor: descriptor,
                        downloadState: modelLibrary.state(for: descriptor),
                        isInstalled: isInstalled,
                        isActive: isInstalled
                            && modelLibrary.destinationURL(for: descriptor).path == activePath,
                        onDownload: {
                            modelLibrary.download(descriptor)
                        },
                        onActivate: {
                            modelLibrary.activate(descriptor, in: settings)
                        },
                        onDelete: {
                            modelLibrary.delete(descriptor, in: settings)
                        }
                    )
                }
            }

            if canCollapse {
                Button(showsAllModels ? "Show less" : "Show \(hiddenModelCount) more") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showsAllModels.toggle()
                    }
                }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(Color.accentColor)
            }
        }
    }

    private var customActiveURL: URL? {
        let trimmedPath = activePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return nil }
        guard FileManager.default.fileExists(atPath: trimmedPath) else { return nil }

        let isManaged = models.contains { descriptor in
            modelLibrary.destinationURL(for: descriptor).path == trimmedPath
        }

        return isManaged ? nil : URL(fileURLWithPath: trimmedPath)
    }

    private var canCollapse: Bool {
        guard let collapsedLimit else { return false }
        let totalCardCount = models.count + (customActiveURL == nil ? 0 : 1)
        return totalCardCount > collapsedLimit
    }

    private var managedVisibleLimit: Int {
        guard let collapsedLimit, !showsAllModels else { return models.count }
        return max(0, collapsedLimit - (customActiveURL == nil ? 0 : 1))
    }

    private var visibleModels: [ManagedModelDescriptor] {
        guard let collapsedLimit, !showsAllModels else { return models }

        var ordered: [ManagedModelDescriptor] = []

        if let activeDescriptor {
            ordered.append(activeDescriptor)
        }

        for id in featuredModelIDs {
            guard let descriptor = models.first(where: { $0.id == id }) else { continue }
            guard !ordered.contains(descriptor) else { continue }
            ordered.append(descriptor)
        }

        for descriptor in models where !ordered.contains(descriptor) {
            ordered.append(descriptor)
        }

        let limit = max(0, collapsedLimit - (customActiveURL == nil ? 0 : 1))
        return Array(ordered.prefix(limit))
    }

    private var activeDescriptor: ManagedModelDescriptor? {
        models.first { descriptor in
            modelLibrary.destinationURL(for: descriptor).path == activePath
                && modelLibrary.isInstalled(descriptor)
        }
    }

    private var hiddenModelCount: Int {
        max(0, models.count - visibleModels.count)
    }
}

private struct ManagedModelCard: View {
    let descriptor: ManagedModelDescriptor
    let downloadState: ManagedModelDownloadState
    let isInstalled: Bool
    let isActive: Bool
    let onDownload: () -> Void
    let onActivate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Text(descriptor.title)
                    .font(.headline)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                actionView
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    ModelBadge(text: descriptor.sizeLabel)
                    ModelBadge(text: descriptor.languageSummary)
                    ModelBadge(text: descriptor.speedSummary)
                    ModelBadge(text: descriptor.qualitySummary)
                }

                Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                    GridRow {
                        ModelBadge(text: descriptor.sizeLabel)
                        ModelBadge(text: descriptor.languageSummary)
                    }

                    GridRow {
                        ModelBadge(text: descriptor.speedSummary)
                        ModelBadge(text: descriptor.qualitySummary)
                    }
                }
            }

            if case .failed(let message) = downloadState {
                Label(message, systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 98, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    isActive ? Color.accentColor : Color(nsColor: .separatorColor).opacity(0.75),
                    lineWidth: isActive ? 1.5 : 1
                )
        )
    }

    @ViewBuilder
    private var actionView: some View {
        switch downloadState {
        case .downloading(let progress):
            Text(progress.map { "\(Int(($0 * 100).rounded()))%" } ?? "Downloading")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        case .failed:
            Button("Retry", action: onDownload)
                .controlSize(.small)
        case .idle:
            if isActive {
                HStack(spacing: 6) {
                    Text("Active")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                        .foregroundStyle(Color.accentColor)

                    deleteButton
                }
            } else if isInstalled {
                HStack(spacing: 6) {
                    Button("Use", action: onActivate)
                        .controlSize(.small)
                    deleteButton
                }
            } else {
                Button("Download", action: onDownload)
                    .controlSize(.small)
            }
        }
    }

    private var deleteButton: some View {
        Button("Delete", role: .destructive, action: onDelete)
            .controlSize(.small)
    }
}

private struct CustomActiveModelCard: View {
    let url: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Text(url.lastPathComponent)
                    .font(.headline)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("Active")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                    .foregroundStyle(Color.accentColor)
            }

            HStack(spacing: 6) {
                ModelBadge(text: "Custom")
                if !url.pathExtension.isEmpty {
                    ModelBadge(text: url.pathExtension.uppercased())
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 98, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.accentColor, lineWidth: 1.5)
        )
    }
}

private struct ModelBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)))
    }
}
