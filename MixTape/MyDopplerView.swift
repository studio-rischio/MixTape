import SwiftUI

/// Tab 1 — read-only dashboard onto the user's existing Doppler library.
///
/// Layout (top to bottom):
/// - Optional `SyncBanner` while the MusicBrainz cache is building/failing.
/// - Four stat tiles (Songs / Artists / Albums / Playlists).
/// - Two side-by-side panels: Recently Added | Most Played.
/// - The user's existing Doppler playlists.
///
/// Reload triggers:
/// - `task(id: settings.libraryURL)` — runs once when the library URL appears
///   or changes (e.g., user picks a new library).
/// - `onChange(of: settings.libraryRevision)` — runs after we write a playlist
///   to Doppler so counts and the playlist list refresh without a manual click.
///
/// `reload()` also kicks off `MetadataCache.beginSync` so the MusicBrainz cache
/// stays in sync with the library as a side-effect of any read cycle.
struct MyDopplerView: View {
    @State private var settings = AppSettings.shared
    @State private var metadataCache = MetadataCache.shared
    @State private var counts: LibraryCounts = .zero
    @State private var recents: [SongRow] = []
    @State private var mostPlayed: [SongRow] = []
    @State private var playlists: [Playlist] = []
    @State private var loadError: String?
    @State private var isLoading = false

    var body: some View {
        Group {
            if settings.libraryURL == nil {
                noLibraryState
            } else if let err = loadError {
                errorState(err)
            } else {
                dashboard
            }
        }
        .task(id: settings.libraryURL) { await reload() }
        .onChange(of: settings.libraryRevision) { _, _ in
            Task { await reload() }
        }
    }

    private var dashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if shouldShowSyncBanner {
                    SyncBanner(
                        phase: metadataCache.phase,
                        cachedCount: metadataCache.cachedArtistCount,
                        onCancel: { metadataCache.cancel() }
                    )
                }
                statsRow
                HStack(alignment: .top, spacing: 16) {
                    songPanel(
                        title: "Recently Added",
                        systemImage: "clock.arrow.circlepath",
                        rows: recents,
                        emptyHint: "No songs in your library yet."
                    ) { row in
                        if let date = row.dateAdded {
                            Text(Self.relativeFormatter.localizedString(for: date, relativeTo: Date()))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    songPanel(
                        title: "Most Played",
                        systemImage: "play.circle",
                        rows: mostPlayed,
                        emptyHint: "Doppler hasn't recorded any plays yet — listen to a few tracks and they'll show up here."
                    ) { row in
                        if let plays = row.playCount {
                            Text("\(plays) play\(plays == 1 ? "" : "s")")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
                playlistsPanel
            }
            .padding(20)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await reload() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
            }
        }
    }

    private var statsRow: some View {
        HStack(spacing: 12) {
            StatTile(value: counts.songs,     label: "Songs",     systemImage: "music.note",       tint: Theme.statTints[0])
            StatTile(value: counts.artists,   label: "Artists",   systemImage: "person.2",         tint: Theme.statTints[1])
            StatTile(value: counts.albums,    label: "Albums",    systemImage: "square.stack",     tint: Theme.statTints[2])
            StatTile(value: counts.playlists, label: "Playlists", systemImage: "music.note.list",  tint: Theme.statTints[3])
        }
    }

    @ViewBuilder
    private func songPanel<Trailing: View>(
        title: String,
        systemImage: String,
        rows: [SongRow],
        emptyHint: String,
        @ViewBuilder secondaryColumn: @escaping (SongRow) -> Trailing
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(Theme.cream)

            if rows.isEmpty {
                Text(emptyHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title)
                                    .lineLimit(1)
                                Text(row.artist ?? "Unknown artist")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            secondaryColumn(row)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        if row.id != rows.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Theme.panelBorder, lineWidth: 1)
        )
    }

    private var playlistsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Playlists", systemImage: "music.note.list")
                .font(.headline)
                .foregroundStyle(Theme.cream)

            if playlists.isEmpty {
                Text("No playlists in your library yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(playlists) { p in
                        HStack {
                            Image(systemName: "music.note.list")
                                .foregroundStyle(Theme.amber)
                            Text(p.name)
                            Spacer()
                            Text("\(p.songCount) song\(p.songCount == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        if p.id != playlists.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Theme.panelBorder, lineWidth: 1)
        )
    }

    private var noLibraryState: some View {
        ContentUnavailableView {
            Label("No Doppler library selected", systemImage: "music.note.house")
        } description: {
            Text("Choose your Library.dopplerdb in Settings (⌘,) to get started.")
        } actions: {
            SettingsLink { Text("Open Settings") }
                .buttonStyle(.borderedProminent)
        }
    }

    private func errorState(_ err: String) -> some View {
        ContentUnavailableView {
            Label("Couldn't read library", systemImage: "exclamationmark.triangle")
                .foregroundStyle(Theme.warning)
        } description: {
            Text(err)
        } actions: {
            Button("Retry") { Task { await reload() } }
            SettingsLink { Text("Open Settings") }
        }
    }

    private var shouldShowSyncBanner: Bool {
        switch metadataCache.phase {
        case .syncing, .failed, .cancelled: return true
        case .idle, .completed: return false
        }
    }

    private func reload() async {
        guard let url = settings.libraryURL else {
            counts = .zero
            recents = []
            mostPlayed = []
            playlists = []
            return
        }
        Log.debug("reload triggered for \(url.lastPathComponent)", category: LogCategory.ui)
        isLoading = true
        defer { isLoading = false }
        let lib = DopplerLibrary(bundleURL: url)
        do {
            try await lib.openReadOnly()
            // `async let` initiates all four queries together; they end up serialized
            // by the actor (single sqlite handle), but writing it this way keeps the
            // call site readable. Total wall time is the same as sequential awaits.
            async let countsTask = lib.libraryCounts()
            async let recentsTask = lib.recentlyAddedSongs(limit: 10)
            async let mostPlayedTask = lib.mostPlayedSongs(limit: 10)
            async let playlistsTask = lib.listPlaylists()
            counts = try await countsTask
            recents = try await recentsTask
            mostPlayed = try await mostPlayedTask
            playlists = try await playlistsTask
            await lib.close()
            loadError = nil

            // Side-effect: kick off (or resume) MusicBrainz sync. No-op if there's
            // nothing missing from the cache. Runs in its own Task — does not block.
            metadataCache.beginSync(libraryBundleURL: url)
        } catch {
            Log.error("reload failed: \(error.localizedDescription)", category: LogCategory.doppler)
            loadError = error.localizedDescription
        }
    }

    static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}

/// One of the four big number+label cards at the top of My Library.
/// `tint` colors the icon glyph and the uppercase label so each stat reads
/// as distinct; the number itself stays in the primary text color so glance
/// readability isn't lost. Background uses the shared `Theme.panel` so the
/// row feels cohesive with the rest of the dashboard's containers.
private struct StatTile: View {
    let value: Int
    let label: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(tint.opacity(0.85))
                    .textCase(.uppercase)
            }
            Text(value.formatted())
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Theme.panelBorder, lineWidth: 1)
        )
    }
}
