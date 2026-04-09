import AppKit
import SwiftUI

@main
struct VoiceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var coordinator = AppCoordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(coordinator: coordinator)
        } label: {
            Label(coordinator.state.menuTitle, systemImage: coordinator.state.menuSymbol)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(settings: coordinator.settings, modelLibrary: coordinator.modelLibrary)
        }
    }
}
