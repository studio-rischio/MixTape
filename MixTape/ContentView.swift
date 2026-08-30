import SwiftUI

/// The main window's root view. A three-tab `TabView` shell — "My Doppler"
/// (read-only dashboard onto the user's library), "Discover" (themes the LLM
/// invents from the library) and "Create" (one playlist from a brief the user
/// types). Tab content lives in `MyDopplerView`, `ShowcaseView` and `CreateView`.
///
/// Also implements the **first-run gate**: when the window first appears, if the
/// LLM provider isn't configured we programmatically open the Settings scene so
/// the user has somewhere to start. Library selection is handled inside Settings,
/// not gated here, because the My Doppler tab has its own no-library empty state.
struct ContentView: View {
    @State private var settings = AppSettings.shared
    @State private var selectedTab: Tab = .myDoppler
    @Environment(\.openSettings) private var openSettings

    /// Tab identity for the `TabView` selection binding. The `showcase` case name
    /// pre-dates the user-visible "Discover" label — the code-side identifier
    /// stays put to avoid churn, as does `ShowcaseView`/`ShowcaseGenerator`.
    enum Tab: Hashable { case myDoppler, showcase, create }

    var body: some View {
        TabView(selection: $selectedTab) {
            MyDopplerView()
                .tabItem { Label("My Doppler", systemImage: "music.note.list") }
                .tag(Tab.myDoppler)

            ShowcaseView()
                .tabItem { Label("Discover", systemImage: "square.grid.2x2") }
                .tag(Tab.showcase)

            CreateView()
                .tabItem { Label("Create", systemImage: "wand.and.stars") }
                .tag(Tab.create)
        }
        .frame(minWidth: 820, minHeight: 540)
        .containerBackground(Theme.windowBackground, for: .window)
        .task {
            // First-run gate: if LM Studio isn't set up we can't generate anything,
            // so push the user straight into Settings rather than leaving them with
            // a non-functional Playlists tab.
            if !settings.isLLMConfigured {
                Log.info("first-run: LLM not configured, opening Settings", category: LogCategory.ui)
                openSettings()
            }
        }
    }
}

#Preview {
    ContentView()
}
