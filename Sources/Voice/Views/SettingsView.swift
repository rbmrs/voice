import AppKit
import SwiftUI

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case transcription
    case refinement
    case speech
    case updates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:
            "General"
        case .transcription:
            "Transcription"
        case .refinement:
            "Refinement"
        case .speech:
            "Speech"
        case .updates:
            "Updates"
        }
    }

    var systemImage: String {
        switch self {
        case .general:
            "gearshape"
        case .transcription:
            "waveform"
        case .refinement:
            "wand.and.stars"
        case .speech:
            "person.wave.2"
        case .updates:
            "arrow.triangle.2.circlepath"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject var settings: AppSettings
    @ObservedObject var modelLibrary: ModelLibrary

    @State private var selectedSection: SettingsSection? = .general
    @State private var isVisible = false

    // macOS does not publish live Accessibility/TCC changes to the process. Poll only while
    // the Settings window is visible, then refresh again when Voice becomes active.
    private let permissionPoll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsSection.allCases, selection: $selectedSection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .frame(width: 190)

            Divider()

            detailView
        }
        .frame(minWidth: 900, idealWidth: 960, minHeight: 620, idealHeight: 700)
        .onReceive(permissionPoll) { _ in
            guard isVisible else { return }
            coordinator.refreshPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            coordinator.refreshPermissions()
        }
        .onAppear {
            isVisible = true
            coordinator.refreshPermissions()
        }
        .onDisappear {
            isVisible = false
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedSection ?? .general {
        case .general:
            GeneralSettingsView(coordinator: coordinator, settings: settings)
        case .transcription:
            TranscriptionSettingsView(settings: settings, modelLibrary: modelLibrary)
        case .refinement:
            RefinementSettingsView(settings: settings, modelLibrary: modelLibrary)
        case .speech:
            SpeechSettingsView(
                settings: settings,
                modelLibrary: modelLibrary,
                monitor: coordinator.sessionSpeech.monitor,
                player: coordinator.sessionSpeech.player
            )
        case .updates:
            UpdatesSettingsView(updater: coordinator.updater)
        }
    }
}
