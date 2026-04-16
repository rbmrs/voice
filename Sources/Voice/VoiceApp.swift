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
            SettingsView(
                coordinator: coordinator,
                settings: coordinator.settings,
                modelLibrary: coordinator.modelLibrary
            )
        }
        .defaultSize(width: 760, height: 980)
        .windowResizability(.contentMinSize)
    }
}
