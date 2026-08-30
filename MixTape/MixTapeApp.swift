import SwiftUI

/// App entry point. Defines three Scenes:
///
/// - `WindowGroup` hosting `ContentView` (the tabbed main window).
/// - `Settings` hosting `SettingsView`, which gives us ⌘, for free.
/// - `Window("Debug Log")` for the in-app log viewer (opened via ⌘⌥L from the
///   Window menu — see `DebugLogMenuItem` below).
///
/// `.preferredColorScheme(.dark)` is applied to each Scene's root view so the
/// app stays dark regardless of the system Appearance setting.
@main
struct MixTapeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
        .commands {
            // Inject our "Debug Log" menu item into the Window menu (right after
            // the standard "Bring All to Front"-style commands).
            CommandGroup(after: .windowArrangement) {
                DebugLogMenuItem()
            }
        }

        Settings {
            SettingsView()
                .preferredColorScheme(.dark)
        }

        Window("Debug Log", id: "debug-log") {
            DebugLogView()
                .preferredColorScheme(.dark)
                .frame(minWidth: 720, minHeight: 360)
        }
        .defaultSize(width: 960, height: 540)
    }
}

/// A trivial helper view that exists only to host `@Environment(\.openSettings)`'s
/// sibling — `\.openWindow` — which can't be used directly inside a `CommandGroup`'s
/// content closure. The button calls `openWindow(id: "debug-log")` to summon the
/// Debug Log Window scene, with ⌘⌥L as a global shortcut.
private struct DebugLogMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Debug Log") {
            openWindow(id: "debug-log")
        }
        .keyboardShortcut("l", modifiers: [.command, .option])
    }
}
