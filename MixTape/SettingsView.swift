import SwiftUI

/// The Settings window (presented automatically via SwiftUI's `Settings` scene
/// on ⌘,). Two tabs:
/// - **LLM**: LM Studio base URL, model picker, Test Connection.
/// - **Library**: Doppler library picker, MusicBrainz cache stats + Reset.
///
/// Sized fixed so the tabs don't resize awkwardly when their content height differs.
struct SettingsView: View {
    var body: some View {
        TabView {
            LLMSettingsTab()
                .tabItem { Label("LLM", systemImage: "brain") }
            LibrarySettingsTab()
                .tabItem { Label("Library", systemImage: "music.note.list") }
        }
        .frame(width: 560, height: 380)
        .containerBackground(Theme.windowBackground, for: .window)
    }
}

/// LM Studio configuration tab. Lets the user set the server URL and pick a
/// loaded model, with a Test Connection button that exercises the same code
/// path the generator uses (`LMStudioClient.listModels`).
///
/// Auto-refreshes the model list once at appear (`.task`); user can manually
/// refresh via the small reload button. The connection-status badge surfaces
/// success or failure of the last Test Connection click.
private struct LLMSettingsTab: View {
    @Bindable private var settings = AppSettings.shared
    @State private var availableModels: [String] = []
    @State private var connectionStatus: ConnectionStatus = .unknown
    @State private var isTesting = false
    @State private var isLoadingModels = false

    enum ConnectionStatus: Equatable {
        case unknown
        case ok(modelCount: Int)
        case failed(String)
    }

    var body: some View {
        Form {
            Section {
                TextField("Base URL", text: $settings.lmStudioBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .help("Default for LM Studio is http://localhost:1234")

                HStack {
                    Picker("Model", selection: $settings.lmStudioModelID) {
                        Text("(none)").tag("")
                        ForEach(availableModels, id: \.self) { id in
                            Text(id).tag(id)
                        }
                    }
                    Button {
                        Task { await refreshModels() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Reload model list from LM Studio")
                    .disabled(isLoadingModels)
                }

                if !settings.lmStudioModelID.isEmpty,
                   !availableModels.isEmpty,
                   !availableModels.contains(settings.lmStudioModelID) {
                    Label(
                        "Selected model isn't currently loaded in LM Studio.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            } header: {
                Label("LM Studio", systemImage: "brain")
                    .foregroundStyle(Theme.lightPurple)
            } footer: {
                Text("Run LM Studio locally and load a model. The default port is 1234.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Test Connection") {
                        Task { await testConnection() }
                    }
                    .disabled(isTesting)

                    if isTesting { ProgressView().controlSize(.small) }

                    Spacer()
                    statusBadge
                }
            }

            Section {
                Stepper(value: $settings.maxConcurrentRequests, in: 1...8) {
                    LabeledContent("Parallel requests") {
                        Text("\(settings.maxConcurrentRequests)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            } footer: {
                Text("How many playlists to generate at the same time. Each in-flight request reserves part of the model's context, so too many at once fails with “Context size has been exceeded”. Lower this if you see that; raise it if your model has a large context.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Pick tracks by number", isOn: $settings.useTrackIDSelection)
            } footer: {
                Text("Asks the model to reply with track numbers instead of retyping every title and artist. Much cheaper, and picks can't fail to match your library. Turn off if your model returns unusable results — small models sometimes follow numbers poorly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await refreshModels() }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch connectionStatus {
        case .unknown:
            EmptyView()
        case .ok(let count):
            Label("Connected · \(count) model\(count == 1 ? "" : "s")", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .failed(let msg):
            Label(msg, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .font(.caption)
                .lineLimit(2)
        }
    }

    private func refreshModels() async {
        guard let url = settings.lmStudioURL else { return }
        isLoadingModels = true
        defer { isLoadingModels = false }
        let client = LMStudioClient(baseURL: url)
        do {
            availableModels = try await client.listModels()
        } catch {
            // Silent — surface via Test Connection instead, so the picker doesn't
            // flash an error every time the URL field is edited.
        }
    }

    private func testConnection() async {
        Log.info("user tapped Test Connection", category: LogCategory.ui)
        guard let url = settings.lmStudioURL else {
            connectionStatus = .failed("Invalid base URL")
            return
        }
        isTesting = true
        defer { isTesting = false }
        let client = LMStudioClient(baseURL: url)
        do {
            let models = try await client.listModels()
            availableModels = models
            connectionStatus = .ok(modelCount: models.count)
        } catch {
            connectionStatus = .failed(error.localizedDescription)
        }
    }
}

/// Library configuration tab. Two sections:
/// - **Doppler Library**: shows the current path, lets the user pick or forget
///   it. Picking validates the choice (must be a `.dopplerdb` bundle with a
///   readable `Contents/library` inside) before persisting the bookmark.
/// - **MusicBrainz Cache**: shows the cached-artists count + initial-sync flag,
///   with a destructive Reset Cache button. Reset auto-kicks a fresh sync if a
///   library is selected.
private struct LibrarySettingsTab: View {
    @Bindable private var settings = AppSettings.shared
    @State private var metadataCache = MetadataCache.shared
    @State private var pickError: String?

    var body: some View {
        Form {
            Section {
                if let url = settings.libraryURL {
                    LabeledContent("Path") {
                        Text(url.path)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } else {
                    Text("No library selected.")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Choose Library…") { pickLibrary() }
                    if settings.libraryURL != nil {
                        Button("Forget Library", role: .destructive) {
                            Log.info("user tapped Forget Library (Settings)", category: LogCategory.ui)
                            settings.updateLibrary(nil)
                        }
                    }
                }

                if let err = pickError {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Label("Doppler Library", systemImage: "music.note.house")
                    .foregroundStyle(Theme.lightPurple)
            } footer: {
                Text("Pick the Library.dopplerdb bundle, normally in ~/Library/Application Support/Doppler/.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if let url = settings.exportFolderURL {
                    LabeledContent("Folder") {
                        Text(url.path)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } else {
                    Text("Not set — you'll be asked the first time you save.")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button("Choose Folder…") { pickExportFolder() }
                    if settings.exportFolderURL != nil {
                        Button("Forget Folder", role: .destructive) {
                            Log.info("user tapped Forget Folder (Settings)", category: LogCategory.ui)
                            settings.updateExportFolder(nil)
                        }
                    }
                }
            } header: {
                Label("Playlist Save Folder", systemImage: "square.and.arrow.down")
                    .foregroundStyle(Theme.lightPurple)
            } footer: {
                Text("Where the Save button writes .m3u files. Track paths are written relative to your Doppler watched folder, so saving inside it keeps them playable. Files are never overwritten — a repeated name gets a number.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Cached artists") {
                    Text("\(metadataCache.cachedArtistCount)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                LabeledContent("Cached tracks") {
                    Text("\(metadataCache.cachedRecordingCount)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                LabeledContent("Initial sync") {
                    Text(metadataCache.hasCompletedInitialSync ? "Complete" : "Not complete")
                        .foregroundStyle(.secondary)
                }

                Button("Reset Cache", role: .destructive) {
                    Task {
                        await metadataCache.reset()
                        if let url = settings.libraryURL {
                            metadataCache.beginSync(libraryBundleURL: url)
                        }
                    }
                }
                .disabled(metadataCache.cachedArtistCount == 0 && !metadataCache.hasCompletedInitialSync)
            } header: {
                Label("MusicBrainz Cache", systemImage: "tray.full")
                    .foregroundStyle(Theme.lightPurple)
            } footer: {
                Text("Clears cached artist and track metadata and re-runs lookups. Useful after fixing a misspelled artist or improving disambiguation. Artist lookups are rate-limited to one per second; track lookups are batched and take seconds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// No `.dopplerdb` validation here — any writable folder is a legitimate
    /// choice, so the only gate is the sandbox grant itself.
    private func pickExportFolder() {
        Log.info("user tapped Choose Folder (Settings)", category: LogCategory.ui)
        guard let picked = PlaylistExportLocation.runFolderPanel(
            defaultDirectory: settings.exportFolderURL
        ) else { return }
        settings.updateExportFolder(picked)
    }

    private func pickLibrary() {
        Log.info("user tapped Choose Library (Settings)", category: LogCategory.ui)
        guard let picked = DopplerLibraryLocation.runOpenPanel() else { return }
        do {
            try DopplerLibraryLocation.validate(picked)
            settings.updateLibrary(picked)
            pickError = nil
        } catch {
            Log.error("settings library pick failed: \(error.localizedDescription)", category: LogCategory.library)
            pickError = error.localizedDescription
        }
    }
}
