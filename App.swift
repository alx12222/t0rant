import SwiftUI

@main
struct T0rantApp: App {
    @StateObject private var shell = Shell()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            TabView {
                TerminalView()
                    .tabItem { Label("Terminal", systemImage: "terminal") }
                FilesView()
                    .tabItem { Label("Files", systemImage: "folder") }
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "gearshape") }
            }
            .environmentObject(shell)
            .preferredColorScheme(.dark)
            .onChange(of: scenePhase) { phase in
                if phase != .active { shell.saveSession() }
            }
        }
    }
}
