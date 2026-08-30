import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Tab 2 — Playlists. The user-visible product surface for LLM-generated
/// playlists. Three layers of gates before the tile grid renders:
///
/// 1. LM Studio configured? (model picked + base URL parses)
/// 2. Doppler library picked?
/// 3. MusicBrainz cache initial sync complete?
///
/// If any gate fails we render a `ContentUnavailableView` that points the user
/// at the right place to fix it (Settings or My Doppler).
///
/// When all gates pass, the body shows a header (title + subtitle + theme-count
/// stepper + Generate button) over a `LazyVGrid` of `ShowcaseTile`s. Tapping a
/// tile opens `ShowcaseDetailSheet` as a modal sheet via `.sheet(item:)`.
struct ShowcaseView: View {
    @State private var settings = AppSettings.shared
    @State private var metadataCache = MetadataCache.shared
    @State private var generator = ShowcaseGenerator.shared
    @State private var detailContext: DetailContext?

    /// Wrapper used to present the detail sheet via `.sheet(item:)`. UUID
    /// doesn't conform to `Identifiable` directly, so we wrap it. The wrapper's
    /// `id` is the entry's UUID so opening a different tile dismisses + re-presents.
    private struct DetailContext: Identifiable {
        let id: UUID
    }

    var body: some View {
        Group {
            if !settings.isLLMConfigured {
                lockedLLMState
            } else if settings.libraryURL == nil {
                noLibraryState
            } else if !metadataCache.hasCompletedInitialSync {
                cacheLockedState
            } else {
                readyState
            }
        }
        .sheet(item: $detailContext) { ctx in
            ShowcaseDetailSheet(entryID: ctx.id)
        }
    }

    // MARK: - Gated states

    private var lockedLLMState: some View {
        ContentUnavailableView {
            Label("LM Studio not configured", systemImage: "lock.fill")
        } description: {
            Text("Pick a model in Settings (⌘,) to unlock generated Playlists.")
        } actions: {
            SettingsLink { Text("Open Settings") }
                .buttonStyle(.borderedProminent)
        }
    }

    private var noLibraryState: some View {
        ContentUnavailableView {
            Label("No Doppler library selected", systemImage: "music.note.house")
        } description: {
            Text("Generated Playlists need your library to draw from.")
        } actions: {
            SettingsLink { Text("Open Settings") }
                .buttonStyle(.borderedProminent)
        }
    }

    private var cacheLockedState: some View {
        ContentUnavailableView {
            Label("Building your library context", systemImage: "hourglass")
        } description: {
            Text(cacheLockedDescription).multilineTextAlignment(.center)
        } actions: {
            if case .syncing(_, let processed, let total, _) = metadataCache.phase {
                ProgressView(value: Double(processed), total: Double(max(total, 1)))
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 320)
            }
        }
    }

    private var cacheLockedDescription: String {
        switch metadataCache.phase {
        case .syncing(.artists, let processed, let total, let current):
            let suffix = current.isEmpty ? "" : " — \(current)"
            return "Looking up \(total) artist\(total == 1 ? "" : "s") on MusicBrainz (\(processed)/\(total))\(suffix). Playlists unlock when this finishes."
        case .syncing(.recordings, let processed, let total, _):
            // Not normally reachable: the tab unlocks as soon as the artist stage
            // finishes, and track matching runs after that. Handled for the case
            // where the flag was cleared by a cache reset mid-run.
            return "Matching your tracks to MusicBrainz (\(processed)/\(total)). Playlists unlock when this finishes."
        case .failed(let msg):
            return "MusicBrainz lookup failed: \(msg)\nPlaylists will unlock once the cache completes — try refreshing My Doppler."
        case .cancelled:
            return "Cache build was cancelled. Refresh My Doppler to resume."
        case .idle, .completed:
            return "Switch to the My Doppler tab to start the initial cache build."
        }
    }

    // MARK: - Ready / generating / generated

    @ViewBuilder
    private var readyState: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Discover").font(.title2.bold())
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            familiarityControl
            trackCountControl
            themeCountControl
            if generator.isGenerating {
                Button("Cancel", role: .destructive) { generator.cancel() }
            } else {
                Button {
                    if let url = settings.libraryURL {
                        generator.generate(libraryURL: url)
                    }
                } label: {
                    Label(generator.discoverEntries.isEmpty ? "Generate" : "Regenerate", systemImage: "sparkles")
                }
                .keyboardShortcut("r", modifiers: .command)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
    }

    /// Filters candidates by global ListenBrainz listen counts before the model
    /// sees them. Needs the recording sync to have run; with no cached counts it
    /// degrades to no-op rather than misbehaving.
    private var familiarityControl: some View {
        Picker("", selection: Binding(
            get: { settings.familiarity },
            set: { settings.familiarity = $0 }
        )) {
            ForEach(AppSettings.Familiarity.allCases, id: \.self) { option in
                Text(option.label).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help(settings.familiarity.help)
        .disabled(generator.isGenerating)
    }

    /// Steps in 5s — the difference between 45 and 46 tracks is meaningless, and
    /// single-stepping from 45 to 100 would be tedious. Shared with the Create tab.
    private var trackCountControl: some View {
        Stepper(
            value: Binding(
                get: { settings.tracksPerPlaylist },
                set: { settings.tracksPerPlaylist = $0 }
            ),
            in: 10...150,
            step: 5
        ) {
            Text("~\(settings.tracksPerPlaylist) tracks")
                .monospacedDigit()
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .help("Target tracks per playlist (10–150). Models undershoot slightly, so treat it as approximate.")
        .disabled(generator.isGenerating)
    }

    private var themeCountControl: some View {
        Stepper(
            value: Binding(
                get: { settings.showcaseThemeCount },
                set: { settings.showcaseThemeCount = $0 }
            ),
            in: 1...20
        ) {
            Text("\(settings.showcaseThemeCount) playlist\(settings.showcaseThemeCount == 1 ? "" : "s")")
                .monospacedDigit()
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .help("How many playlists to generate per run (1–20).")
        .disabled(generator.isGenerating)
    }

    private var headerSubtitle: String {
        switch generator.phase {
        case .idle:
            return generator.discoverEntries.isEmpty
                ? "\(metadataCache.cachedArtistCount) artists in your library context"
                : "Last generated \(generator.lastGeneratedAt?.formatted(.relative(presentation: .named)) ?? "—")"
        case .loadingContext:
            return "Loading library context…"
        case .generatingThemes:
            return "Step 1 of 2 · Picking playlist themes…"
        case .generatingPlaylists(let completed, let total):
            return "Step 2 of 2 · Filling tracks (\(completed)/\(total) playlists)"
        case .ready:
            return "Last generated \(generator.lastGeneratedAt?.formatted(.relative(presentation: .named)) ?? "just now")"
        case .failed(let msg):
            return "Failed: \(msg)"
        case .cancelled:
            return "Cancelled."
        }
    }

    @ViewBuilder
    private var content: some View {
        switch generator.phase {
        case .idle where generator.discoverEntries.isEmpty:
            ContentUnavailableView {
                Label("No playlists yet", systemImage: "sparkles")
            } description: {
                Text("Tap Generate to ask LM Studio for \(settings.showcaseThemeCount) themed playlists drawn from your library.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loadingContext, .generatingThemes:
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text(headerSubtitle).font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let msg) where generator.discoverEntries.isEmpty:
            ContentUnavailableView {
                Label("Generation failed", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.warning)
            } description: {
                Text(msg)
            } actions: {
                Button("Try Again") {
                    if let url = settings.libraryURL {
                        generator.generate(libraryURL: url)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            tileGrid
        }
    }

    private var tileGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 260, maximum: 360), spacing: 16)],
                spacing: 16
            ) {
                ForEach(generator.discoverEntries) { entry in
                    ShowcaseTile(entry: entry)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            detailContext = DetailContext(id: entry.id)
                        }
                }
            }
            .padding(20)
        }
    }
}

// MARK: - Tile

/// One card in the LazyVGrid. Renders a colored gradient background unique to
/// the theme name, the name + description, and a status chip that reflects
/// `entry.state`. Tapping anywhere on the tile opens the detail sheet (the tap
/// gesture lives on the parent `ForEach`).
struct ShowcaseTile: View {
    let entry: ShowcaseEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundStyle(.white.opacity(0.65))
                Spacer()
                if entry.dopplerPlaylistID != nil {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.white)
                        .help("Added to Doppler")
                }
            }

            Spacer(minLength: 0)

            Text(entry.name)
                .font(.title3.bold())
                .foregroundStyle(.white)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Text(entry.description)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(3)

            HStack {
                stateChip
                Spacer()
            }
        }
        .padding(16)
        .frame(minHeight: 180, maxHeight: 220)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.gradient(for: entry.name), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var stateChip: some View {
        switch entry.state {
        case .generating:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini).tint(.white)
                Text("Picking tracks…").font(.caption2)
            }
            .foregroundStyle(.white.opacity(0.9))
        case .ready:
            Text(matchedSummary)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
        case .failed:
            Label("Failed", systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(Theme.warning)
        }
    }

    private var matchedSummary: String {
        if entry.matchedTrackCount == entry.trackCount {
            return "\(entry.trackCount) tracks · all owned"
        }
        return "\(entry.matchedTrackCount)/\(entry.trackCount) owned"
    }

    /// Deterministic colored gradient per theme name so each tile feels distinct.
    /// Uses an FNV-1a hash of the name to pick a hue (0-360°) — same input always
    /// gives the same color across launches. The detail sheet's banner uses this
    /// same function for visual continuity. `static` so callers (e.g., the sheet)
    /// can reuse the gradient for a given name.
    static func gradient(for name: String) -> LinearGradient {
        // FNV-1a 32-bit hash. We can't use Swift's default `hashValue` because
        // it's randomized per process and would give different colors each launch.
        var hash: UInt32 = 2166136261
        for scalar in name.unicodeScalars {
            hash ^= scalar.value
            hash = hash &* 16777619
        }
        let hue1 = Double(hash % 360) / 360.0
        let hue2 = (hue1 + 0.08).truncatingRemainder(dividingBy: 1.0)
        return LinearGradient(
            colors: [
                Color(hue: hue1, saturation: 0.62, brightness: 0.52),
                Color(hue: hue2, saturation: 0.50, brightness: 0.30),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - Detail sheet

/// Modal sheet shown when the user taps a tile. Mirrors the tile's gradient
/// banner at the top, then renders the full tracklist (or the generating /
/// failed state body), then a footer with the Add+ button.
///
/// Holds the entry's UUID rather than the entry value: the source of truth is
/// `generator.entries`, looked up by id on every `body` evaluation. That way
/// when `addToDoppler` flips `dopplerPlaylistID` the sheet immediately re-renders
/// with the green ✓ pill — no manual refresh needed.
struct ShowcaseDetailSheet: View {
    let entryID: UUID

    @State private var generator = ShowcaseGenerator.shared
    @State private var settings = AppSettings.shared
    @State private var isAdding = false
    @State private var addError: String?
    @State private var isExporting = false
    @State private var exportError: String?
    /// Where the last one-click Save landed. Drives the "Saved" button state and
    /// the footer caption — without a save panel appearing there's otherwise no
    /// feedback that anything happened.
    @State private var savedURL: URL?
    @State private var isRetrying = false
    @Environment(\.dismiss) private var dismiss

    /// Live lookup against the generator's entries. Returns `nil` if the
    /// generator state has been cleared (e.g., user hit Regenerate). The body
    /// renders a "Playlist removed" empty state in that case.
    private var entry: ShowcaseEntry? {
        generator.entries.first { $0.id == entryID }
    }

    var body: some View {
        Group {
            if let entry {
                VStack(spacing: 0) {
                    banner(entry)
                    Divider()
                    content(entry)
                    Divider()
                    footer(entry)
                }
            } else {
                ContentUnavailableView(
                    "Playlist removed",
                    systemImage: "questionmark.circle"
                )
            }
        }
        .frame(width: 560, height: 640)
        .alert("Couldn't add to Doppler", isPresented: Binding(
            get: { addError != nil },
            set: { if !$0 { addError = nil } }
        )) {
            Button("OK") { addError = nil }
        } message: {
            Text(addError ?? "")
        }
        .alert("Couldn't export .m3u", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    private func banner(_ entry: ShowcaseEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(.white.opacity(0.7))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.8))
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }
            Spacer(minLength: 0)
            Text(entry.name)
                .font(.title.bold())
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Text(entry.description)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 160, alignment: .leading)
        .background(ShowcaseTile.gradient(for: entry.name))
    }

    @ViewBuilder
    private func content(_ entry: ShowcaseEntry) -> some View {
        switch entry.state {
        case .generating:
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Picking tracks from \(entry.plannedArtists.count) artists…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(entry.plannedArtists.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready(let tracks):
            trackList(tracks)
        case .failed(let msg):
            ContentUnavailableView {
                Label("Couldn't pick tracks", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.warning)
            } description: {
                Text(msg)
            } actions: {
                Button {
                    Task { await performRetry() }
                } label: {
                    if isRetrying {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Retrying…")
                        }
                    } else {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRetrying || generator.isGenerating)
            }
        }
    }

    private func trackList(_ tracks: [GeneratedTrack]) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { idx, track in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(idx + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 24, alignment: .trailing)
                        Image(systemName: track.dopplerSongID != nil ? "music.note" : "questionmark.circle")
                            .foregroundStyle(track.dopplerSongID != nil ? Color.secondary : Theme.warning)
                            .font(.caption)
                            .frame(width: 14)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title)
                                .strikethrough(track.dopplerSongID == nil, color: Theme.warning)
                                .lineLimit(1)
                            Text(track.artist)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 14)
                    if idx < tracks.count - 1 {
                        Divider().padding(.leading, 54)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func footer(_ entry: ShowcaseEntry) -> some View {
        HStack(spacing: 12) {
            if case .ready(let tracks) = entry.state {
                let addable = tracks.lazy.filter { $0.dopplerSongID != nil }.count
                let missing = tracks.count - addable
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(addable) of \(tracks.count) tracks in your library")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if missing > 0 {
                        Text("\(missing) track\(missing == 1 ? "" : "s") will be skipped on add")
                            .font(.caption2)
                            .foregroundStyle(Theme.warning)
                    }
                    // In ID mode a track can't fail to resolve, so there's nothing to
                    // strike through — the model either picked a valid number or it
                    // didn't. This is the equivalent signal. Rejected ids and the
                    // reason (out of range vs duplicate) go to the Debug Log.
                    if entry.unusablePicks > 0 {
                        Text("\(entry.unusablePicks) unusable pick\(entry.unusablePicks == 1 ? "" : "s") discarded — see Debug Log")
                            .font(.caption2)
                            .foregroundStyle(Theme.warning)
                    }
                    if let savedURL {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([savedURL])
                        } label: {
                            Label("Saved \(savedURL.lastPathComponent)", systemImage: "folder")
                                .font(.caption2)
                        }
                        .buttonStyle(.link)
                        .help(savedURL.path)
                    }
                }
                Spacer()
                // Split button: the primary action is the one-click save into the
                // remembered folder; the menu keeps the original save-panel export
                // (and the way to change folders) without spending a third slot in
                // a 560pt-wide footer.
                Menu {
                    Button("Export .m3u…") { Task { await performExport() } }
                    Divider()
                    if let folder = settings.exportFolderURL {
                        Button("Show Save Folder in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([folder])
                        }
                    }
                    Button(settings.exportFolderURL == nil ? "Choose Save Folder…" : "Change Save Folder…") {
                        chooseSaveFolder()
                    }
                } label: {
                    if isExporting {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Saving…")
                        }
                    } else if savedURL != nil {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                    } else {
                        Label("Save .m3u", systemImage: "square.and.arrow.down")
                    }
                } primaryAction: {
                    Task { await performSave() }
                }
                .menuStyle(.button)
                .fixedSize()
                .controlSize(.large)
                .disabled(isExporting || addable == 0)
                .help(settings.exportFolderURL.map { "Save to \($0.path)" }
                    ?? "Pick a folder once, then save with one click")

                if entry.dopplerPlaylistID != nil {
                    Label("Added to Doppler", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                } else {
                    Button {
                        Task { await performAdd() }
                    } label: {
                        if isAdding {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Adding…")
                            }
                        } else {
                            Label("Add \(addable) to Doppler", systemImage: "plus.circle.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isAdding || addable == 0)
                }
            } else {
                Text("Playlist isn't ready yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }
            }
        }
        .padding(16)
    }

    private func performRetry() async {
        isRetrying = true
        defer { isRetrying = false }
        await ShowcaseGenerator.shared.retryEntry(entryID: entryID)
    }

    private func performAdd() async {
        isAdding = true
        defer { isAdding = false }
        do {
            _ = try await ShowcaseGenerator.shared.addToDoppler(entryID: entryID)
        } catch {
            addError = error.localizedDescription
        }
    }

    /// One-click save into the remembered folder — no panel.
    ///
    /// Builds the .m3u exactly once and reuses it across every branch below; the
    /// obvious structuring (ask the generator to save, catch "no folder", ask
    /// again) re-opens the library on each attempt.
    ///
    /// Two paths still need the picker: the very first Save, when no folder has
    /// been granted, and a folder that has since been deleted or unmounted —
    /// which `PlaylistExportLocation.write` reports as `.folderUnavailable`.
    /// Rather than dead-ending on an alert, drop the stale grant and re-prompt.
    private func performSave() async {
        isExporting = true
        defer { isExporting = false }
        Log.info("user tapped Save .m3u", category: LogCategory.ui)
        do {
            let export = try await ShowcaseGenerator.shared.exportM3U(entryID: entryID)

            var folder = settings.exportFolderURL
            if folder == nil {
                folder = pickSaveFolder(defaultDirectory: export.suggestedDirectory)
            }
            guard let destination = folder else { return }

            do {
                savedURL = try write(export, into: destination)
            } catch PlaylistExportLocation.WriteError.folderUnavailable(let stale) {
                Log.warning("export folder \(stale.path) is gone — re-prompting", category: LogCategory.playlist)
                settings.updateExportFolder(nil)
                guard let replacement = pickSaveFolder(defaultDirectory: export.suggestedDirectory) else { return }
                savedURL = try write(export, into: replacement)
            }
        } catch {
            exportError = error.localizedDescription
        }
    }

    private func write(_ export: M3UExport, into folder: URL) throws -> URL {
        let url = try PlaylistExportLocation.write(
            export.text,
            fileName: export.suggestedFileName,
            into: folder
        )
        Log.info("saved .m3u (\(export.trackCount) tracks, \(export.missingCount) missing) to \(url.path)", category: LogCategory.playlist)
        return url
    }

    /// Runs the folder picker and persists the grant. Defaults to Doppler's
    /// watched-folder root when we know it — .m3u paths are written relative to
    /// that root, so saving there is what keeps them resolvable.
    private func pickSaveFolder(defaultDirectory: URL?) -> URL? {
        guard let picked = PlaylistExportLocation.runFolderPanel(defaultDirectory: defaultDirectory) else {
            return nil
        }
        settings.updateExportFolder(picked)
        return picked
    }

    /// Menu action: change the save folder without saving anything. Falls back to
    /// the current folder as the panel's starting point, since there's no entry
    /// export to recover a watched-folder root from here.
    private func chooseSaveFolder() {
        _ = pickSaveFolder(defaultDirectory: settings.exportFolderURL)
    }

    /// Builds the .m3u text on a background actor, then presents an
    /// `NSSavePanel` so the user picks where to save it. Defaults the panel
    /// to the Doppler library's watched-folder root (recovered from the
    /// first track's bookmark) so the relative paths in the file resolve
    /// when launched from a music player pointed at that root.
    private func performExport() async {
        isExporting = true
        defer { isExporting = false }
        do {
            let export = try await ShowcaseGenerator.shared.exportM3U(entryID: entryID)
            // NSSavePanel must be presented + read on the main actor.
            let panel = NSSavePanel()
            if let m3uType = UTType(filenameExtension: "m3u") {
                panel.allowedContentTypes = [m3uType]
            }
            panel.nameFieldStringValue = export.suggestedFileName
            panel.canCreateDirectories = true
            if let dir = export.suggestedDirectory {
                panel.directoryURL = dir
            }
            guard panel.runModal() == .OK, let target = panel.url else {
                Log.debug("user cancelled .m3u save panel", category: LogCategory.ui)
                return
            }
            try export.text.write(to: target, atomically: true, encoding: .utf8)
            savedURL = target
            Log.info("wrote .m3u (\(export.trackCount) tracks, \(export.missingCount) missing) to \(target.path)", category: LogCategory.playlist)
        } catch {
            exportError = error.localizedDescription
        }
    }
}
