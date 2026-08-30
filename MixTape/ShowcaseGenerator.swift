import Foundation
import Observation

/// One LLM-named track after we've tried to resolve it against the user's
/// Doppler library. `dopplerSongID == nil` means the LLM named a track we
/// couldn't find — surfaced in the UI with a strikethrough title and dropped
/// from the actual write to Doppler. `id` is `"title|artist"` because Doppler
/// might not have a song ID for this row, and SwiftUI needs a stable identifier
/// for `ForEach`.
struct GeneratedTrack: Identifiable, Hashable, Sendable {
    /// Prefer the Doppler song ID when we have one — it's genuinely unique, whereas
    /// `title|artist` collides when the same song sits on two albums (a compilation
    /// and the original, say), which would give `ForEach` duplicate identifiers.
    /// Falls back to the string form for tracks that never resolved.
    var id: String { dopplerSongID.map(String.init) ?? "\(title)|\(artist)" }
    let title: String
    let artist: String
    /// Doppler `ZSNRSONG.Z_PK` if we resolved this track to one in the user's library.
    /// `nil` means the LLM named a track we couldn't find.
    let dopplerSongID: Int64?
}

/// One slot in the Showcase grid. Shape arrives in pass 1 (themes); state flips
/// from `.generating` to `.ready` (or `.failed`) as each per-theme pass-2 call returns.
struct ShowcaseEntry: Identifiable, Sendable {
    let id: UUID
    let name: String
    let description: String
    let plannedArtists: [String]
    var state: State
    /// Set after the user successfully Adds this playlist to Doppler. The Z_PK
    /// allocated in `ZPERSISTENTPLAYLIST`. Disables the Add button when present.
    var dopplerPlaylistID: Int64?
    /// Which tab produced this entry. Both kinds live in the same `entries` array
    /// so `addToDoppler`/`exportM3U`/`retryEntry` can find either by UUID without
    /// caring where it came from; the two tabs just filter on this.
    var source: Source = .discover
    /// The user's own words, for `.created` entries. Kept so a retry can rebuild
    /// the same request, and so the UI can show what was asked for.
    var brief: String?

    enum Source: Sendable, Equatable {
        /// Themes the model invented by looking at the library (Discover tab).
        case discover
        /// A playlist built from a brief the user typed (Create tab).
        case created
    }

    enum State: Sendable {
        case generating
        case ready(tracks: [GeneratedTrack])
        case failed(message: String)
    }

    /// How many of the LLM's picks we had to throw away. In string mode this stays
    /// 0 (unresolvable tracks are kept and struck through instead). In ID mode it
    /// counts indices that were out of range or repeated — the model failing to
    /// follow the format, which is the only way ID selection can go wrong.
    var unusablePicks: Int = 0

    var matchedTrackCount: Int {
        guard case .ready(let tracks) = state else { return 0 }
        return tracks.lazy.filter { $0.dopplerSongID != nil }.count
    }

    var trackCount: Int {
        guard case .ready(let tracks) = state else { return 0 }
        return tracks.count
    }
}

/// Pass-2 output for one theme: the resolved tracklist plus how many of the LLM's
/// picks were discarded getting there.
struct ThemeTracks: Sendable {
    let tracks: [GeneratedTrack]
    let unusablePicks: Int
}

/// Result of building an .m3u for a single Showcase entry. The view layer takes
/// this, presents an `NSSavePanel` (defaulted to `suggestedDirectory`/`suggestedFileName`),
/// and writes `text` to disk. `missingCount` lets the UI surface a soft warning
/// when some tracks couldn't be resolved to a file — the export still succeeds
/// with whatever paths we did get.
struct M3UExport: Sendable {
    let text: String
    let suggestedFileName: String
    let suggestedDirectory: URL?
    let trackCount: Int
    let missingCount: Int
}

/// Errors thrown by `ShowcaseGenerator.exportM3U`. Separate from `ShowcaseError`
/// because export failures are user-recoverable (re-pick a library, regenerate
/// the playlist) rather than pipeline failures.
enum ShowcaseExportError: LocalizedError {
    case noLibrary
    case entryNotFound
    case notReady
    case noResolvableTracks

    var errorDescription: String? {
        switch self {
        case .noLibrary: return "No Doppler library selected. Open Settings (⌘,) and pick one."
        case .entryNotFound: return "That playlist is no longer available."
        case .notReady: return "Playlist isn't finished generating yet."
        case .noResolvableTracks: return "None of this playlist's tracks could be located on disk."
        }
    }
}

/// Errors from the "more like this" similarity walk. Separate from `ShowcaseError`
/// because none of them involve the LLM — they're all about missing ListenBrainz
/// data, which is a normal outcome for obscure tracks rather than a malfunction.
enum ShowcaseSimilarError: LocalizedError {
    case seedNotFound
    case seedNotMatched(String)
    case noSimilarData(String)

    var errorDescription: String? {
        switch self {
        case .seedNotFound:
            return "That track is no longer in your library."
        case .seedNotMatched(let title):
            return "“\(title)” hasn't been matched to MusicBrainz yet, so there's nothing to compare it against. Let the track sync finish on My Doppler and try again."
        case .noSimilarData(let title):
            return "ListenBrainz has no listening data for “\(title)”, or nothing similar to it is in your library. This is common for lesser-known artists — try a more widely played track."
        }
    }
}

/// Errors specific to the generation pipeline. LMStudioClient and
/// MetadataCacheStore have their own error types — these are the ones we throw
/// from `ShowcaseGenerator.runSync` when a precondition or response shape isn't
/// what we expected.
enum ShowcaseError: LocalizedError {
    case notConfigured
    case noArtistsCached
    case invalidResponse(String)
    case noUsableThemes

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "LM Studio isn't configured. Open Settings (⌘,) and pick a model."
        case .noArtistsCached:
            return "No artists in the metadata cache yet. Run a sync from My Doppler first."
        case .invalidResponse(let m):
            return "LM Studio returned a response we couldn't parse: \(m)"
        case .noUsableThemes:
            return "The model didn't return any themes that overlap with your library."
        }
    }
}

/// Two-pass Showcase generator:
///   Pass 1 (themes): tiny prompt with artist names + tags + albums, returns
///   N themes (`AppSettings.showcaseThemeCount`, default 9, range 1–20).
///   Pass 2 (per theme, parallel): for each theme, ship only its artists' real
///   song titles and ask the model to pick 45 tracks. Each playlist appears in
///   the `entries` array as soon as its pass-2 call resolves; a per-tile Retry
///   button on the detail sheet calls `retryEntry(entryID:)` to redo just one
///   failure without rebuilding the whole batch.
@MainActor
@Observable
final class ShowcaseGenerator {
    static let shared = ShowcaseGenerator()

    /// State machine driving the Playlists tab UI. The header shows a different
    /// subtitle per case; cards render placeholders during `generatingPlaylists`
    /// and flip to ready/failed as their pass-2 calls return.
    enum Phase: Equatable, Sendable {
        case idle
        case loadingContext
        case generatingThemes
        case generatingPlaylists(completed: Int, total: Int)
        case ready
        case failed(String)
        case cancelled
    }

    /// Separate state machine for the Create tab so a request in flight doesn't
    /// disturb the Discover grid's phase (and vice versa) — the two tabs run
    /// independently and a user can start a request while a batch is generating.
    enum CreatePhase: Equatable, Sendable {
        case idle
        /// `progress` is 0...1 when we can honestly say how far along we are, and
        /// `nil` when we can't — the view shows a determinate bar for the former
        /// and an indeterminate one for the latter rather than inventing a number.
        case working(status: String, progress: Double?)
        case failed(String)

        var status: String? {
            if case .working(let status, _) = self { return status }
            return nil
        }

        var progress: Double? {
            if case .working(_, let progress) = self { return progress }
            return nil
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var createPhase: CreatePhase = .idle
    private var createTask: Task<Void, Never>?

    var isCreating: Bool {
        if case .working = createPhase { return true } else { return false }
    }

    /// Entries the Discover tab shows — themes the model came up with on its own.
    var discoverEntries: [ShowcaseEntry] { entries.filter { $0.source == .discover } }

    /// Entries the Create tab shows, newest first, so a fresh request appears at
    /// the top rather than scrolling off the bottom.
    var createdEntries: [ShowcaseEntry] { entries.filter { $0.source == .created }.reversed() }
    /// One entry per generated playlist. Populated after pass 1 with `.generating`
    /// state; entries flip to `.ready`/`.failed` independently as pass-2 calls return.
    /// Mutating in place (vs replacing the whole array) lets SwiftUI animate row
    /// transitions instead of redrawing the whole grid.
    private(set) var entries: [ShowcaseEntry] = []
    private(set) var lastGeneratedAt: Date?

    private var generationTask: Task<Void, Never>?

    /// True during loadingContext / generatingThemes / generatingPlaylists. Used
    /// to disable the Generate button and the theme-count Stepper while a run is
    /// in flight.
    var isGenerating: Bool {
        switch phase {
        case .loadingContext, .generatingThemes, .generatingPlaylists: return true
        default: return false
        }
    }

    /// Kicks off a generation run. No-op if one's already running. Detached
    /// `Task` so the caller (a button handler) returns immediately.
    func generate(libraryURL: URL) {
        if isGenerating {
            Log.debug("ShowcaseGenerator already running; ignoring", category: LogCategory.llm)
            return
        }
        let url = libraryURL
        generationTask = Task { [weak self] in
            await self?.run(libraryURL: url)
        }
    }

    /// Cancels both pass 1 and any in-flight pass-2 calls. The `withTaskGroup`
    /// inside `run` propagates cancellation to its child tasks, so all 6+
    /// per-theme requests bail at their next `Task.checkCancellation()` (or
    /// their next URLSession await — `URLSession.data(for:)` honors cancellation).
    func cancel() {
        Log.info("user cancelled showcase generation", category: LogCategory.ui)
        generationTask?.cancel()
    }

    /// Writes the entry's playlist into Doppler. Throws `DopplerLibraryWriter.WriteError`
    /// on failure (most commonly `dopplerRunning`). On success, marks the entry as added
    /// and bumps `AppSettings.libraryRevision` so observers (My Doppler) re-fetch.
    func addToDoppler(entryID: UUID) async throws -> Int64 {
        Log.info("user tapped Add to Doppler", category: LogCategory.ui)
        guard let url = AppSettings.shared.libraryURL else {
            throw DopplerLibraryWriter.WriteError.cannotOpen("no library selected")
        }
        guard let idx = entries.firstIndex(where: { $0.id == entryID }) else {
            throw DopplerLibraryWriter.WriteError.query("entry not found")
        }
        guard case .ready(let tracks) = entries[idx].state else {
            throw DopplerLibraryWriter.WriteError.query("playlist isn't ready yet")
        }
        // Dedupe — Z_7SONGS has UNIQUE(playlist, song); the LLM occasionally repeats
        // the same track in long playlists, which would roll the whole transaction back.
        var seen = Set<Int64>()
        let songIDs = tracks.compactMap(\.dopplerSongID).filter { seen.insert($0).inserted }
        let dropped = tracks.compactMap(\.dopplerSongID).count - songIDs.count
        if dropped > 0 {
            Log.warning("dropped \(dropped) duplicate track\(dropped == 1 ? "" : "s") from playlist '\(entries[idx].name)' before insert", category: LogCategory.doppler)
        }
        guard !songIDs.isEmpty else { throw DopplerLibraryWriter.WriteError.noSongs }

        let writer = DopplerLibraryWriter(bundleURL: url)
        try await writer.open()
        do {
            let pk = try await writer.createPlaylist(name: entries[idx].name, songIDs: songIDs)
            await writer.close()
            entries[idx].dopplerPlaylistID = pk
            AppSettings.shared.libraryRevision &+= 1
            return pk
        } catch {
            await writer.close()
            throw error
        }
    }

    /// Builds one playlist from a brief the user typed ("Italian dinner night",
    /// "biking trip"). Same two passes as `generate()`, with two differences:
    /// pass 1 is asked for exactly one theme *in service of the brief* rather than
    /// N themes of its own invention, and the result is appended to `entries` as a
    /// `.created` entry instead of replacing the Discover grid.
    ///
    /// Runs on its own task and phase so it doesn't interfere with a Discover
    /// generation that might already be in flight.
    func create(brief: String, libraryURL: URL) {
        let trimmed = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if isCreating {
            Log.debug("create ignored: a request is already running", category: LogCategory.llm)
            return
        }
        Log.info("user requested a playlist: \"\(trimmed)\"", category: LogCategory.ui)
        createTask = Task { [weak self] in
            await self?.runCreate(brief: trimmed, libraryURL: libraryURL)
        }
    }

    func cancelCreate() {
        Log.info("user cancelled playlist request", category: LogCategory.ui)
        createTask?.cancel()
    }

    private func runCreate(brief: String, libraryURL: URL) async {
        // Tracked outside the `do` so the failure paths can resolve an entry that
        // was already appended. Without this a pass-2 failure leaves the tile stuck
        // on "generating" forever: no Retry, and Add/Export throw `notReady`.
        var pendingEntryID: UUID?
        do {
            let settings = AppSettings.shared
            guard let lmURL = settings.lmStudioURL, !settings.lmStudioModelID.isEmpty else {
                throw ShowcaseError.notConfigured
            }
            let model = settings.lmStudioModelID
            let trackTarget = settings.tracksPerPlaylist
            let familiarity = settings.familiarity

            createPhase = .working(status: "Reading your library…", progress: 0)
            try await MetadataCacheStore.shared.open()
            let artists = try await MetadataCacheStore.shared.loadAllArtistRecords()
            guard !artists.isEmpty else { throw ShowcaseError.noArtistsCached }
            // Empty when the recording sync hasn't run; `applyFamiliarity` then
            // falls back to leaving the candidate order alone.
            let popularity = familiarity == .balanced
                ? [:]
                : try await MetadataCacheStore.shared.popularityByKey()

            let lib = DopplerLibrary(bundleURL: libraryURL)
            try await lib.openReadOnly()
            defer { Task { await lib.close() } }

            let songsByArtist = try await lib.sampleSongsByArtist(
                perArtistLimit: AppSettings.perArtistLimit(forTarget: trackTarget)
                    * Self.familiarityPoolMultiplier(familiarity)
            )
            let albumsByArtist = try await lib.albumsByArtist()

            // Pass 1 — one theme, shaped by the brief.
            try Task.checkCancellation()
            createPhase = .working(status: "Choosing artists for “\(brief)”…", progress: 1.0 / 3.0)
            let prompt = Self.buildBriefThemePrompt(
                brief: brief,
                artists: artists,
                albumsByArtist: albumsByArtist
            )
            let client = LMStudioClient(baseURL: lmURL)
            let raw = try await client.chatCompletion(
                model: model,
                messages: [.system(prompt.system), .user(prompt.user)],
                temperature: 0.85,
                maxTokens: 8192,
                responseSchema: Self.themesSchema
            )
            try Task.checkCancellation()

            // Reuses `themesSchema` and takes the first theme rather than adding a
            // near-identical single-theme schema — LM Studio's grammar is happier
            // with a shape it's already generating well.
            guard let theme = try Self.parseThemes(raw).first else {
                throw ShowcaseError.noUsableThemes
            }

            let entryID = UUID()
            pendingEntryID = entryID
            entries.append(
                ShowcaseEntry(
                    id: entryID,
                    name: theme.name,
                    description: theme.description,
                    plannedArtists: theme.artists,
                    state: .generating,
                    source: .created,
                    brief: brief
                )
            )

            // Pass 2 — tracks.
            createPhase = .working(status: "Picking tracks for “\(theme.name)”…", progress: 2.0 / 3.0)
            let result = try await Self.generateTracksForTheme(
                theme,
                lmURL: lmURL,
                model: model,
                lib: lib,
                songsByArtist: songsByArtist,
                useTrackIDs: settings.useTrackIDSelection,
                trackTarget: trackTarget,
                familiarity: familiarity,
                popularity: popularity
            )
            if let idx = entries.firstIndex(where: { $0.id == entryID }) {
                entries[idx].state = .ready(tracks: result.tracks)
                entries[idx].unusablePicks = result.unusablePicks
            }
            createPhase = .idle
            Log.info(
                "created '\(theme.name)' from brief: \(result.tracks.lazy.filter { $0.dopplerSongID != nil }.count)/\(result.tracks.count) matched",
                category: LogCategory.llm
            )
        } catch is CancellationError {
            // Drop the placeholder rather than leaving a dead tile behind — the
            // user asked for this to stop, so there's nothing worth keeping.
            if let id = pendingEntryID {
                entries.removeAll { $0.id == id }
            }
            createPhase = .idle
            Log.info("playlist request cancelled", category: LogCategory.llm)
        } catch {
            // Mark it failed so the tile shows the error and its Retry button works
            // — `retryEntry` rebuilds the theme from the stored name/description/
            // plannedArtists, which a `.created` entry has just like a Discover one.
            if let id = pendingEntryID, let idx = entries.firstIndex(where: { $0.id == id }) {
                entries[idx].state = .failed(message: error.localizedDescription)
            }
            createPhase = .failed(error.localizedDescription)
            Log.error("playlist request failed: \(error.localizedDescription)", category: LogCategory.llm)
        }
    }

    /// Builds a playlist of tracks the user owns that listeners play alongside a
    /// seed track. **No LLM involved** — this is collaborative filtering over real
    /// listening histories from ListenBrainz, so it works with LM Studio closed.
    ///
    /// A single seed is nowhere near enough. Measured against a 2,923-track
    /// library, one seed's similar list overlaps the library by only ~4 tracks
    /// (7.6% of ~57 results), so this walks breadth-first: seed → similar → keep
    /// the ones you own → those become the next frontier. The endpoint takes many
    /// seeds per request, so each level is one call rather than one per track.
    ///
    /// Ordering is by level then similarity score, so tracks closest to the seed
    /// come first and the playlist drifts outward — which is roughly what "more
    /// like this" should feel like.
    /// Takes the seed's title and artist rather than just its `Z_PK`, because the
    /// picker hands back the primary key of whichever row matched, while
    /// `allSongIdentities` groups by canonical `(artist, title)` and keeps only
    /// `MIN(Z_PK)`. For a song that sits on two albums those differ, and an ID-based
    /// lookup would fail on the copy that lost the MIN.
    func createSimilar(seedTitle: String, seedArtist: String?, libraryURL: URL) {
        if isCreating {
            Log.debug("similar ignored: a request is already running", category: LogCategory.llm)
            return
        }
        createTask = Task { [weak self] in
            await self?.runCreateSimilar(seedTitle: seedTitle, seedArtist: seedArtist ?? "", libraryURL: libraryURL)
        }
    }

    private func runCreateSimilar(seedTitle: String, seedArtist: String, libraryURL: URL) async {
        var pendingEntryID: UUID?
        do {
            let trackTarget = AppSettings.shared.tracksPerPlaylist
            createPhase = .working(status: "Reading your library…", progress: 0)

            try await MetadataCacheStore.shared.open()
            let keysByMBID = try await MetadataCacheStore.shared.recordingKeysByMBID()
            let mbidsByKey = try await MetadataCacheStore.shared.mbidsByRecordingKey()

            let lib = DopplerLibrary(bundleURL: libraryURL)
            try await lib.openReadOnly()
            defer { Task { await lib.close() } }
            let identities = try await lib.allSongIdentities()

            // One index, keyed the way SQL keyed it — that's what `mb_recording`
            // and therefore `keysByMBID` use. The seed is canonicalized with
            // `sqlCanonicalize` for the same reason: Swift's Unicode lowercasing
            // would produce a different key for uppercase non-ASCII and never match.
            var byKey: [String: SongIdentity] = [:]
            for identity in identities {
                byKey[MetadataCacheStore.recordingKey(
                    artist: identity.canonicalArtist,
                    title: identity.canonicalTitle
                )] = identity
            }

            let seedKey = MetadataCacheStore.recordingKey(
                artist: MetadataCache.sqlCanonicalize(seedArtist),
                title: MetadataCache.sqlCanonicalize(seedTitle)
            )
            guard let seed = byKey[seedKey] else {
                throw ShowcaseSimilarError.seedNotFound
            }
            guard let seedMBID = mbidsByKey[seedKey] else {
                throw ShowcaseSimilarError.seedNotMatched(seed.title)
            }

            let entryID = UUID()
            pendingEntryID = entryID
            let name = "More like \(seed.title)"
            entries.append(
                ShowcaseEntry(
                    id: entryID,
                    name: name,
                    description: "Tracks you own that listeners play alongside “\(seed.title)” by \(seed.artist).",
                    plannedArtists: [seed.artist],
                    state: .generating,
                    source: .created,
                    brief: "More like \(seed.title) — \(seed.artist)"
                )
            )

            let lb = ListenBrainzClient()
            var collected: [(identity: SongIdentity, level: Int, score: Int)] = []
            var seenKeys: Set<String> = [seedKey]
            var frontier: [String] = [seedMBID]
            var level = 0
            // Four levels is plenty: each one roughly triples reach, and beyond
            // that the results have drifted far enough from the seed that
            // "more like this" stops being true.
            let maxLevels = 4

            while !frontier.isEmpty, collected.count < trackTarget, level < maxLevels {
                try Task.checkCancellation()
                level += 1
                createPhase = .working(
                    status: "Finding similar tracks (step \(level))…",
                    progress: Double(collected.count) / Double(max(trackTarget, 1))
                )

                // One request for the whole frontier. Cap it so a wide level can't
                // build an absurd URL.
                let batch = Array(frontier.prefix(50))
                let similar = try await lb.similarRecordings(to: batch)
                var nextFrontier: [String] = []

                for row in similar.sorted(by: { $0.score > $1.score }) {
                    guard let key = keysByMBID[row.recordingMBID],
                          let identity = byKey[key],
                          !seenKeys.contains(key)
                    else { continue }
                    seenKeys.insert(key)
                    collected.append((identity, level, row.score))
                    nextFrontier.append(row.recordingMBID)
                    if collected.count >= trackTarget { break }
                }

                Log.info(
                    "similar walk level \(level): \(batch.count) seeds -> \(similar.count) similar, \(collected.count)/\(trackTarget) owned so far",
                    category: LogCategory.llm
                )
                createPhase = .working(
                    status: "Found \(collected.count) of \(trackTarget) tracks…",
                    progress: Double(collected.count) / Double(max(trackTarget, 1))
                )
                frontier = nextFrontier
            }

            guard !collected.isEmpty else {
                throw ShowcaseSimilarError.noSimilarData(seed.title)
            }

            // Closest first: earlier levels, then higher similarity within a level.
            // The seed leads its own playlist — "more like X" that doesn't contain
            // X is oddly incomplete to listen to.
            let ordered = collected
                .sorted { ($0.level, -$0.score) < ($1.level, -$1.score) }
                .prefix(max(0, trackTarget - 1))

            let tracks =
                [GeneratedTrack(title: seed.title, artist: seed.artist, dopplerSongID: seed.songID)]
                + ordered.map {
                    GeneratedTrack(title: $0.identity.title, artist: $0.identity.artist, dopplerSongID: $0.identity.songID)
                }
            if let idx = entries.firstIndex(where: { $0.id == entryID }) {
                entries[idx].state = .ready(tracks: tracks)
            }
            createPhase = .idle
            Log.info("similar playlist '\(name)': \(tracks.count) tracks over \(level) level(s)", category: LogCategory.llm)
        } catch is CancellationError {
            if let id = pendingEntryID { entries.removeAll { $0.id == id } }
            createPhase = .idle
            Log.info("similar request cancelled", category: LogCategory.llm)
        } catch {
            // Unlike a brief-based request there's nothing to retry — Retry re-runs
            // pass 2 against an LLM, which this path never used. Drop the tile and
            // report on the header instead.
            if let id = pendingEntryID { entries.removeAll { $0.id == id } }
            createPhase = .failed(error.localizedDescription)
            Log.error("similar request failed: \(error.localizedDescription)", category: LogCategory.llm)
        }
    }

    /// Re-runs pass 2 for a single entry. Lets the user retry one failed
    /// playlist without rebuilding the whole batch (or burning another LLM
    /// call to repick themes). Reconstructs the original `ProposedTheme` from
    /// the entry's stored name/description/plannedArtists — those are exactly
    /// the inputs `generateTracksForTheme` needs. No-op if a full generation
    /// run is already in progress (would compete for state); also no-op if
    /// LLM/library aren't configured (the retry button is hidden in that case
    /// but guard anyway).
    func retryEntry(entryID: UUID) async {
        Log.info("user tapped retry on a single playlist", category: LogCategory.ui)
        if isGenerating {
            Log.debug("retry ignored: full generation in progress", category: LogCategory.llm)
            return
        }
        let settings = AppSettings.shared
        guard let url = settings.libraryURL,
              let lmURL = settings.lmStudioURL,
              !settings.lmStudioModelID.isEmpty else { return }
        let model = settings.lmStudioModelID
        let trackTarget = settings.tracksPerPlaylist
        let familiarity = settings.familiarity
        guard let idx = entries.firstIndex(where: { $0.id == entryID }) else { return }

        let theme = ProposedTheme(
            name: entries[idx].name,
            description: entries[idx].description,
            artists: entries[idx].plannedArtists
        )
        entries[idx].state = .generating

        let lib = DopplerLibrary(bundleURL: url)
        do {
            try await MetadataCacheStore.shared.open()
            let popularity = familiarity == .balanced
                ? [:]
                : try await MetadataCacheStore.shared.popularityByKey()
            try await lib.openReadOnly()
            let songsByArtist = try await lib.sampleSongsByArtist(
                perArtistLimit: AppSettings.perArtistLimit(forTarget: trackTarget)
                    * Self.familiarityPoolMultiplier(familiarity)
            )
            let result = try await Self.generateTracksForTheme(
                theme,
                lmURL: lmURL,
                model: model,
                lib: lib,
                songsByArtist: songsByArtist,
                useTrackIDs: settings.useTrackIDSelection,
                trackTarget: trackTarget,
                familiarity: familiarity,
                popularity: popularity
            )
            await lib.close()
            if let i = entries.firstIndex(where: { $0.id == entryID }) {
                let tracks = result.tracks
                entries[i].state = .ready(tracks: tracks)
                entries[i].unusablePicks = result.unusablePicks
                Log.info(
                    "retry of '\(entries[i].name)' done: \(tracks.lazy.filter { $0.dopplerSongID != nil }.count)/\(tracks.count) matched, \(result.unusablePicks) unusable",
                    category: LogCategory.llm
                )
            }
        } catch {
            await lib.close()
            if let i = entries.firstIndex(where: { $0.id == entryID }) {
                entries[i].state = .failed(message: error.localizedDescription)
                Log.warning("retry of '\(entries[i].name)' failed: \(error.localizedDescription)", category: LogCategory.llm)
            }
        }
    }

    /// Builds an Extended M3U for the given entry. Order matches the LLM-chosen
    /// tracklist (what the user sees in the detail sheet). Uses paths relative
    /// to Doppler's watched-folder root (e.g. `Tycho/Dive/01 A Walk.mp3`) so
    /// the file plays back from any music app launched in that directory.
    /// Tracks the LLM named but we couldn't match to the library are skipped;
    /// tracks with bookmarks we couldn't decode are reported via `missingCount`.
    func exportM3U(entryID: UUID) async throws -> M3UExport {
        // Neutral wording: this is the shared builder behind both Save and
        // Export…, so the "user tapped X" line belongs to each caller.
        Log.debug("building .m3u for entry \(entryID)", category: LogCategory.playlist)
        guard let url = AppSettings.shared.libraryURL else {
            throw ShowcaseExportError.noLibrary
        }
        guard let entry = entries.first(where: { $0.id == entryID }) else {
            throw ShowcaseExportError.entryNotFound
        }
        guard case .ready(let tracks) = entry.state else {
            throw ShowcaseExportError.notReady
        }
        let songIDs = tracks.compactMap(\.dopplerSongID)
        guard !songIDs.isEmpty else { throw ShowcaseExportError.noResolvableTracks }

        let lib = DopplerLibrary(bundleURL: url)
        try await lib.openReadOnly()
        defer { Task { await lib.close() } }
        let locations = try await lib.songLocations(forIDs: songIDs)

        var libraryRoot: String?
        var pathLines: [String] = []
        var missing = 0
        for t in tracks {
            guard let id = t.dopplerSongID, let loc = locations[id] else {
                missing += 1
                continue
            }
            if libraryRoot == nil, let r = loc.libraryRoot { libraryRoot = r }
            if let p = loc.relativePath {
                pathLines.append(p)
            } else {
                missing += 1
            }
        }
        guard !pathLines.isEmpty else { throw ShowcaseExportError.noResolvableTracks }

        // #PLAYLIST: tags must be a single line; sanitize newlines just in case
        // an LLM-generated name slipped one through.
        let safeName = entry.name
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let body = ["#EXTM3U", "#PLAYLIST:\(safeName)"] + pathLines
        let text = body.joined(separator: "\n") + "\n"

        Log.info("exportM3U: \(pathLines.count) paths, \(missing) missing for '\(entry.name)'", category: LogCategory.playlist)
        return M3UExport(
            text: text,
            suggestedFileName: Self.sanitizedFilename(entry.name) + ".m3u",
            suggestedDirectory: libraryRoot.map { URL(fileURLWithPath: $0) },
            trackCount: pathLines.count,
            missingCount: missing
        )
    }

    /// Strips characters that aren't valid in a macOS filename (`/`, `:`, plus
    /// control bytes) and trims surrounding whitespace. We don't try to escape
    /// every Windows-illegal character — the user can rename in the save panel.
    private static func sanitizedFilename(_ s: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        let cleaned = s.components(separatedBy: invalid).joined(separator: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Playlist" : trimmed
    }

    // MARK: - Orchestration

    private func run(libraryURL: URL) async {
        do {
            let settings = AppSettings.shared
            guard let lmURL = settings.lmStudioURL, !settings.lmStudioModelID.isEmpty else {
                throw ShowcaseError.notConfigured
            }
            let model = settings.lmStudioModelID
            let trackTarget = settings.tracksPerPlaylist
            let familiarity = settings.familiarity

            // 1. Load context.
            phase = .loadingContext
            try await MetadataCacheStore.shared.open()
            let artists = try await MetadataCacheStore.shared.loadAllArtistRecords()
            guard !artists.isEmpty else { throw ShowcaseError.noArtistsCached }
            // Empty when the recording sync hasn't run; `applyFamiliarity` then
            // falls back to leaving the candidate order alone.
            let popularity = familiarity == .balanced
                ? [:]
                : try await MetadataCacheStore.shared.popularityByKey()

            let lib = DopplerLibrary(bundleURL: libraryURL)
            try await lib.openReadOnly()
            defer { Task { await lib.close() } }

            let songsByArtist = try await lib.sampleSongsByArtist(
                perArtistLimit: AppSettings.perArtistLimit(forTarget: trackTarget)
                    * Self.familiarityPoolMultiplier(familiarity)
            )
            let albumsByArtist = try await lib.albumsByArtist()

            // 2. Pass 1: themes.
            try Task.checkCancellation()
            phase = .generatingThemes
            // Clear only this tab's entries — anything the user built in Create
            // is theirs and shouldn't vanish because they hit Regenerate here.
            entries.removeAll { $0.source == .discover }

            let themeCount = AppSettings.shared.showcaseThemeCount
            let themesPrompt = Self.buildThemesPrompt(
                artists: artists,
                albumsByArtist: albumsByArtist,
                themeCount: themeCount
            )
            Log.info("themes prompt built: \(themesPrompt.user.count) user chars (target \(themeCount) themes)", category: LogCategory.llm)

            let client = LMStudioClient(baseURL: lmURL)
            let themesRaw = try await client.chatCompletion(
                model: model,
                messages: [.system(themesPrompt.system), .user(themesPrompt.user)],
                temperature: 0.85,
                maxTokens: 8192,
                responseSchema: Self.themesSchema
            )
            try Task.checkCancellation()

            let themes = try Self.parseThemes(themesRaw)
            Log.info("got \(themes.count) themes from LLM", category: LogCategory.llm)
            guard !themes.isEmpty else { throw ShowcaseError.noUsableThemes }

            // 3. Seed entries with placeholders so the UI can render the grid immediately.
            let seeded = themes.map { theme in
                ShowcaseEntry(
                    id: UUID(),
                    name: theme.name,
                    description: theme.description,
                    plannedArtists: theme.artists,
                    state: .generating
                )
            }
            entries.removeAll { $0.source == .discover }
            entries.append(contentsOf: seeded)
            phase = .generatingPlaylists(completed: 0, total: seeded.count)

            // 4. Pass 2: per-theme tracks, parallel.
            // Read the flag here on the main actor — `generateTracksForTheme` is
            // `static` and runs off-actor inside the task group, so it can't touch
            // `AppSettings.shared` itself.
            let useTrackIDs = settings.useTrackIDSelection
            // Bounded, not unbounded. One request per theme all firing at once
            // exhausts LM Studio's KV cache ("Context size has been exceeded") and
            // kills most of the batch. Parallelism is still worth having — it beat
            // serial by ~30s on a 4-request batch — so cap it rather than drop it.
            let maxInFlight = max(1, settings.maxConcurrentRequests)
            Log.info("pass 2: \(seeded.count) themes, up to \(maxInFlight) at a time", category: LogCategory.llm)

            await withTaskGroup(of: (UUID, Result<ThemeTracks, Error>).self) { group in
                let work = Array(zip(seeded, themes))
                var next = 0

                // Built once and reused by both the priming loop and the refill, so
                // the capture list can't drift between them.
                let makeTask: @Sendable (UUID, ProposedTheme) -> @Sendable @isolated(any) () async -> (UUID, Result<ThemeTracks, Error>) = { id, theme in
                    {
                        do {
                            try Task.checkCancellation()
                            let result = try await Self.generateTracksForTheme(
                                theme,
                                lmURL: lmURL,
                                model: model,
                                lib: lib,
                                songsByArtist: songsByArtist,
                                useTrackIDs: useTrackIDs,
                                trackTarget: trackTarget,
                                familiarity: familiarity,
                                popularity: popularity
                            )
                            return (id, .success(result))
                        } catch {
                            return (id, .failure(error))
                        }
                    }
                }

                while next < work.count, next < maxInFlight {
                    group.addTask(operation: makeTask(work[next].0.id, work[next].1))
                    next += 1
                }

                var completed = 0
                while let (id, result) = await group.next() {
                    if let idx = entries.firstIndex(where: { $0.id == id }) {
                        switch result {
                        case .success(let themeTracks):
                            let tracks = themeTracks.tracks
                            entries[idx].state = .ready(tracks: tracks)
                            entries[idx].unusablePicks = themeTracks.unusablePicks
                            Log.info(
                                "theme '\(entries[idx].name)' done: \(tracks.lazy.filter { $0.dopplerSongID != nil }.count)/\(tracks.count) matched, \(themeTracks.unusablePicks) unusable",
                                category: LogCategory.llm
                            )
                        case .failure(let err):
                            entries[idx].state = .failed(message: err.localizedDescription)
                            Log.warning("theme '\(entries[idx].name)' failed: \(err.localizedDescription)", category: LogCategory.llm)
                        }
                    }
                    completed += 1
                    phase = .generatingPlaylists(completed: completed, total: seeded.count)

                    // Start the next theme only as a slot frees up.
                    if next < work.count, !Task.isCancelled {
                        group.addTask(operation: makeTask(work[next].0.id, work[next].1))
                        next += 1
                    }
                }
            }

            try Task.checkCancellation()
            lastGeneratedAt = Date()
            phase = .ready
            let discover = discoverEntries
            let totalTracks = discover.reduce(0) { $0 + $1.trackCount }
            let totalMatched = discover.reduce(0) { $0 + $1.matchedTrackCount }
            Log.info(
                "showcase ready: \(discover.count) entries, \(totalMatched)/\(totalTracks) tracks matched",
                category: LogCategory.llm
            )
        } catch is CancellationError {
            phase = .cancelled
            Log.info("showcase generation cancelled", category: LogCategory.llm)
        } catch {
            phase = .failed(error.localizedDescription)
            Log.error("showcase generation failed: \(error.localizedDescription)", category: LogCategory.llm)
        }
    }

    // MARK: - Per-theme pass 2

    /// Pass 2 for a single theme. Three steps:
    /// 1. Filter the LLM's chosen artists down to ones that are actually in the
    ///    user's library (the LLM occasionally hallucinates artists). If nothing
    ///    survives the filter, throw — the caller marks the entry as failed.
    /// 2. Build the per-theme prompt with only those artists' real song titles
    ///    and call LM Studio with a `tracksSchema` json_schema response_format.
    /// 3. Resolve each `(title, artist)` pair against Doppler. We try a strict
    ///    `(title AND artist)` match first, then fall back to title-only — the
    ///    LLM sometimes formats artist strings differently from `ZRAWARTIST`
    ///    (e.g., "X feat. Y" vs "X").
    ///
    /// `static` because it doesn't touch any of `ShowcaseGenerator`'s mutable
    /// state — keeps the `withTaskGroup` capture list short and Sendable-clean.
    private static func generateTracksForTheme(
        _ theme: ProposedTheme,
        lmURL: URL,
        model: String,
        lib: DopplerLibrary,
        songsByArtist: [String: [SongCandidate]],
        useTrackIDs: Bool,
        trackTarget: Int,
        familiarity: AppSettings.Familiarity,
        popularity: [String: Int]
    ) async throws -> ThemeTracks {
        // Filter the theme's artists to ones we actually have in the library.
        struct ArtistWithSongs {
            let displayName: String
            let songs: [SongCandidate]
        }
        let perArtist = AppSettings.perArtistLimit(forTarget: trackTarget)
        let usable: [ArtistWithSongs] = theme.artists.compactMap { name in
            let canonical = MetadataCache.canonicalize(name)
            guard let songs = songsByArtist[canonical], !songs.isEmpty else { return nil }
            return ArtistWithSongs(
                displayName: name,
                songs: applyFamiliarity(
                    songs,
                    canonicalArtist: canonical,
                    familiarity: familiarity,
                    popularity: popularity,
                    limit: perArtist
                )
            )
        }
        guard !usable.isEmpty else {
            throw ShowcaseError.invalidResponse("theme '\(theme.name)' has no artists in the user's library")
        }

        let client = LMStudioClient(baseURL: lmURL)

        if useTrackIDs {
            let built = buildTrackIDsPrompt(theme: theme, artists: usable.map { ($0.displayName, $0.songs) }, target: trackTarget)
            Log.debug(
                "tracks prompt (id mode) for '\(theme.name)': \(built.prompt.user.count) chars, \(built.index.count) candidates across \(usable.count) artists",
                category: LogCategory.llm
            )

            let raw = try await client.chatCompletion(
                model: model,
                messages: [.system(built.prompt.system), .user(built.prompt.user)],
                temperature: 0.7,
                maxTokens: max(3500, trackTarget * 25),
                responseSchema: trackIDsSchema
            )
            let proposed = try parseTrackIDs(raw)

            // An in-range index is by construction a song the user owns, so there's
            // nothing to re-resolve. Discard out-of-range and repeated indices; those
            // are the only way this can fail, and they mean the model ignored the format.
            var resolved: [GeneratedTrack] = []
            var seenSongIDs = Set<Int64>()
            var outOfRange: [Int] = []
            var duplicates: [Int] = []
            for id in proposed.ids {
                guard let candidate = built.index[id] else {
                    outOfRange.append(id)
                    continue
                }
                // Dedupe on the song ID rather than the prompt index: the
                // `Z_7SONGS UNIQUE(playlist, song)` constraint is what actually
                // rolls back the insert, and it keys on the song.
                guard seenSongIDs.insert(candidate.songID).inserted else {
                    duplicates.append(id)
                    continue
                }
                resolved.append(
                    GeneratedTrack(title: candidate.title, artist: candidate.artist, dopplerSongID: candidate.songID)
                )
            }

            let unusable = outOfRange.count + duplicates.count
            if unusable > 0 {
                Log.warning(
                    "theme '\(theme.name)': \(unusable) unusable picks — \(outOfRange.count) out of range \(outOfRange.prefix(10))\(outOfRange.count > 10 ? "…" : ""), \(duplicates.count) duplicate \(duplicates.prefix(10))\(duplicates.count > 10 ? "…" : "")",
                    category: LogCategory.llm
                )
            }
            // A run of consecutive indices is the tell for a model that counted
            // instead of choosing; log enough to spot it without dumping everything.
            Log.debug("theme '\(theme.name)' picked ids: \(proposed.ids.prefix(20))\(proposed.ids.count > 20 ? "…" : "")", category: LogCategory.llm)

            return ThemeTracks(tracks: resolved, unusablePicks: unusable)
        }

        let prompt = buildTracksPrompt(theme: theme, artists: usable.map { ($0.displayName, $0.songs.map(\.title)) }, target: trackTarget)
        Log.debug("tracks prompt for '\(theme.name)': \(prompt.user.count) chars across \(usable.count) artists", category: LogCategory.llm)

        let raw = try await client.chatCompletion(
            model: model,
            messages: [.system(prompt.system), .user(prompt.user)],
            temperature: 0.7,
            maxTokens: max(3500, trackTarget * 25),
            responseSchema: tracksSchema
        )
        let proposed = try parseTracks(raw)

        // Resolve each (title, artist) against Doppler. Strict match first; loose
        // (title-only) fallback rescues the cases where the LLM mangled the artist
        // string but got the title right.
        var resolved: [GeneratedTrack] = []
        for t in proposed.tracks {
            try Task.checkCancellation()
            var match = try? await lib.findSong(title: t.title, artist: t.artist)
            if match == nil {
                match = try? await lib.findSong(title: t.title, artist: nil)
            }
            resolved.append(GeneratedTrack(title: t.title, artist: t.artist, dopplerSongID: match?.id))
        }
        return ThemeTracks(tracks: resolved, unusablePicks: 0)
    }

    // MARK: - Prompt builders

    private struct PromptPair {
        let system: String
        let user: String
    }

    /// Constructs the pass-1 (themes) prompt. The user message embeds a compact
    /// JSON payload of `{"artists": [{name, tags[≤3], albums[≤4]?}]}` — small
    /// enough to fit in tight context windows. The system message asks for
    /// exactly `themeCount` themes back.
    ///
    /// Tags and albums are deliberately truncated to keep the prompt small for
    /// users with low LM Studio context limits — too long and the request fails
    /// with "n_keep > n_ctx". 3 tags + 4 albums is the sweet spot found during
    /// development.
    private static func buildThemesPrompt(
        artists: [MBArtistRecord],
        albumsByArtist: [String: [String]],
        themeCount: Int
    ) -> PromptPair {
        let system = """
        You are a thoughtful music curator helping a user explore the music they already own.

        Step 1 of 2: propose \(themeCount) themed playlist concepts based on the user's library.

        Each theme must include:
        - "name": a creative, evocative title (3-7 words)
        - "description": one or two sentences capturing the mood, situation, era, sub-genre, or unexpected vibe
        - "artists": 8-12 artists from the provided list whose music fits the theme. Use the artist's "name" string verbatim. The same artist may appear in multiple themes.

        Vary the themes meaningfully across the \(themeCount) — different moods, eras, energy levels, sub-genres. Avoid generic genre dumps.

        Respond with valid JSON in this shape, and nothing else:
        {"themes": [{"name": "...", "description": "...", "artists": ["...", "..."]}]}
        """

        struct ArtistEntry: Encodable {
            let name: String
            let tags: [String]
            let albums: [String]?
        }
        let entries = artists.map { a -> ArtistEntry in
            let canonical = MetadataCache.canonicalize(a.name)
            let albums = albumsByArtist[canonical]?.prefix(4).map { $0 } ?? []
            return ArtistEntry(
                name: a.name,
                tags: Array(a.tags.prefix(3)),
                albums: albums.isEmpty ? nil : albums
            )
        }

        let json = encodeCompact(["artists": entries])

        let user = """
        Here is the user's library — each artist with up to 3 representative tags and up to 4 of their albums:

        \(json)

        Propose \(themeCount) themes.
        """

        return PromptPair(system: system, user: user)
    }

    /// Constructs the pass-2 (tracks-for-one-theme) prompt. The user message
    /// embeds the theme metadata + per-artist song lists as JSON; the system
    /// message tells the LLM to pick exactly 45 tracks from those lists.
    ///
    /// "Exactly N" beats "8-15 range" in practice — LLMs hit specific numbers
    /// more reliably than ranges. The unique-track rule is critical: the
    /// `Z_7SONGS` UNIQUE constraint would roll back the whole playlist insert
    /// otherwise (we also dedupe in `addToDoppler` as a belt-and-suspenders).
    private static func buildTracksPrompt(
        theme: ProposedTheme,
        artists: [(String, [String])],
        target: Int
    ) -> PromptPair {
        let system = """
        You are a thoughtful music curator. Step 2 of 2: pick the tracks for one playlist theme.

        Pick exactly \(target) tracks that best fit the theme. Rules:
        - Select tracks ONLY from the "tracks" arrays in the provided artist list. Do not invent songs.
        - Each track must be unique within this playlist — never include the same (title, artist) pair twice.
        - Use each track's title verbatim from the provided list. For "artist", use the "name" string verbatim.
        - Mix multiple artists across the \(target) tracks; don't lean too heavily on any single one.
        - Sequence the tracks so the playlist flows well — vary tempo and mood across the order.

        Respond with valid JSON in this shape, and nothing else:
        {"tracks": [{"title": "...", "artist": "..."}]}
        """

        struct ArtistEntry: Encodable {
            let name: String
            let tracks: [String]
        }
        let entries = artists.map { ArtistEntry(name: $0.0, tracks: $0.1) }

        let body: [String: Any] = [
            "theme": [
                "name": theme.name,
                "description": theme.description,
            ],
            "artists": entries.compactMap { entry -> [String: Any]? in
                guard let data = try? JSONEncoder().encode(entry),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                return obj
            },
        ]
        let json = (try? JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        let user = """
        Theme and the artists' songs you own are below. Pick exactly \(target) unique tracks for this playlist, sequenced for flow.

        \(json)
        """

        return PromptPair(system: system, user: user)
    }

    /// One numbered candidate in the ID-mode prompt, and what it resolves back to.
    private struct IndexedCandidate {
        let songID: Int64
        let title: String
        let artist: String
    }

    private struct BuiltTrackIDsPrompt {
        let prompt: PromptPair
        /// Prompt number -> the song it stands for. Sparse lookups are why this is
        /// a dictionary rather than an array: an out-of-range id just misses.
        let index: [Int: IndexedCandidate]
    }

    /// Narrows one artist's candidate songs by how well-known they are globally.
    ///
    /// `.balanced` is a pass-through, so the pre-familiarity behaviour is exactly
    /// preserved. For the other two the caller has already fetched a wider pool
    /// (see `familiarityPoolMultiplier`) and this trims it back to `limit` from
    /// whichever end the user asked for.
    ///
    /// Tracks with no cached listen count — roughly 10% of a real library, plus
    /// everything if the recording sync hasn't run — are treated as **median**,
    /// not as zero. Ranking unknowns as obscure would stuff "deep cuts" with
    /// tracks whose only distinction is a typo in the metadata.
    private static func applyFamiliarity(
        _ songs: [SongCandidate],
        canonicalArtist: String,
        familiarity: AppSettings.Familiarity,
        popularity: [String: Int],
        limit: Int
    ) -> [SongCandidate] {
        guard familiarity != .balanced, songs.count > limit else {
            return Array(songs.prefix(limit))
        }

        // `canonicalTitle` comes from SQLite's `LOWER(TRIM(...))`, which is what
        // `mb_recording` is keyed on. Re-lowercasing in Swift here would silently
        // miss for uppercase non-ASCII titles, degrading every lookup to median.
        func count(_ song: SongCandidate) -> Int? {
            popularity[MetadataCacheStore.recordingKey(
                artist: canonicalArtist,
                title: song.canonicalTitle
            )]
        }

        let counts = songs.compactMap(count)
        // No popularity data at all for this artist — nothing to rank on, so leave
        // the order (most recently added first) alone rather than shuffling blindly.
        guard !counts.isEmpty else { return Array(songs.prefix(limit)) }
        let median = counts.sorted()[counts.count / 2]

        // Sort on (score, original index). `sorted(by:)` is not stable, and when
        // only a few tracks have counts the rest all tie on `median` — without the
        // index tiebreak the ZDATEADDED order would be destroyed and `prefix`
        // would keep an arbitrary, run-to-run different subset.
        let ranked = songs.enumerated()
            .map { (index: $0.offset, song: $0.element, score: count($0.element) ?? median) }
            .sorted {
                if $0.score != $1.score {
                    return familiarity == .hits ? $0.score > $1.score : $0.score < $1.score
                }
                return $0.index < $1.index
            }
        return ranked.prefix(limit).map(\.song)
    }

    /// How much wider a pool to pull from the library when a familiarity
    /// preference is set: there's no point ranking by popularity if the candidate
    /// list has already been truncated to exactly what we'll use.
    static func familiarityPoolMultiplier(_ familiarity: AppSettings.Familiarity) -> Int {
        familiarity == .balanced ? 1 : 3
    }

    /// Pass 1 for the Create tab: one theme built around the user's own words.
    ///
    /// Same artist payload as `buildThemesPrompt` (≤3 tags, ≤4 albums each) because
    /// the prompt-size budget is the same — this still has to fit a small context
    /// window. The difference is entirely in the instructions: the model is told to
    /// serve the brief and to interpret it loosely rather than literally, since a
    /// request like "Italian dinner night" describes a *mood*, and a library rarely
    /// contains music that literally matches the words.
    private static func buildBriefThemePrompt(
        brief: String,
        artists: [MBArtistRecord],
        albumsByArtist: [String: [String]]
    ) -> PromptPair {
        let system = """
        You are a thoughtful music curator helping a user build one playlist from their own library.

        Step 1 of 2: the user will describe an occasion, mood, activity or vibe. Turn it into a single playlist concept using only artists from the provided list.

        Return exactly one theme with:
        - "name": a creative, evocative title for this playlist (3-7 words). Don't just echo the user's words back.
        - "description": one or two sentences explaining how this fits what they asked for.
        - "artists": 8-12 artists from the provided list whose music suits the request. Use each artist's "name" string verbatim.

        Interpret the request by feel, not literally. "Italian dinner night" means warm, unhurried, convivial music — not necessarily Italian artists. If the library has nothing that fits closely, choose the closest match in mood and say so in the description.

        Respond with valid JSON in this shape, and nothing else:
        {"themes": [{"name": "...", "description": "...", "artists": ["...", "..."]}]}
        """

        struct ArtistEntry: Encodable {
            let name: String
            let tags: [String]
            let albums: [String]?
        }
        let entries = artists.map { a -> ArtistEntry in
            let canonical = MetadataCache.canonicalize(a.name)
            let albums = albumsByArtist[canonical]?.prefix(4).map { $0 } ?? []
            return ArtistEntry(
                name: a.name,
                tags: Array(a.tags.prefix(3)),
                albums: albums.isEmpty ? nil : albums
            )
        }
        let json = encodeCompact(["artists": entries])

        let user = """
        The user asked for: "\(brief)"

        Here is their library — each artist with up to 3 representative tags and up to 4 of their albums:

        \(json)

        Propose one playlist theme for this request.
        """

        return PromptPair(system: system, user: user)
    }

    /// Constructs the pass-2 prompt in ID mode. Candidates are numbered in one flat
    /// sequence across all artists (not per artist) — a single namespace is smaller
    /// and gives the model no chance to confuse "track 3 of Radiohead" with "track 3".
    ///
    /// The model replies `{"ids":[…]}`, so it never re-types a title. That's ~18x
    /// cheaper on output tokens than echoing `{"title","artist"}` per track, and it
    /// removes string matching from the resolve path entirely.
    ///
    /// Deliberately a plain numbered list rather than JSON: measured at roughly the
    /// same size as the JSON encoding for the input, and easier for a small model to
    /// read than nested arrays.
    private static func buildTrackIDsPrompt(
        theme: ProposedTheme,
        artists: [(String, [SongCandidate])],
        target: Int
    ) -> BuiltTrackIDsPrompt {
        let system = """
        You are a thoughtful music curator. Step 2 of 2: pick the tracks for one playlist theme.

        Pick exactly \(target) tracks that best fit the theme. Rules:
        - Every track is listed below with a number. Reply with those numbers only.
        - Use ONLY numbers that appear in the list. Never invent a number.
        - Each number must appear at most once — no repeats.
        - Mix multiple artists across the \(target) tracks; don't lean too heavily on any single one.
        - Order the numbers so the playlist flows well — vary tempo and mood across the order.

        Respond with valid JSON in this shape, and nothing else:
        {"ids": [12, 4, 87]}
        """

        var index: [Int: IndexedCandidate] = [:]
        var lines: [String] = []
        var n = 0
        for (artistName, songs) in artists {
            lines.append("\(artistName):")
            for song in songs {
                n += 1
                index[n] = IndexedCandidate(songID: song.id, title: song.title, artist: artistName)
                lines.append("\(n) \(song.title)")
            }
        }

        let user = """
        Theme: \(theme.name)
        \(theme.description)

        Tracks you own, numbered:

        \(lines.joined(separator: "\n"))

        Pick exactly \(target) of these numbers, sequenced for flow.
        """

        return BuiltTrackIDsPrompt(prompt: PromptPair(system: system, user: user), index: index)
    }

    private static func encodeCompact<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }

    // MARK: - Schemas (LM Studio json_schema)
    //
    // All schemas omit `additionalProperties: false`, `strict: true`, and
    // `minItems`/`maxItems` constraints. We tried adding them; LM Studio's
    // constrained-decoding grammar choked on the combination and produced empty
    // output. The simpler shape leaves the model free to generate anything that
    // *matches* the keys we declare. Counts ("exactly 45") belong in the prompt
    // text, not here.

    private static let themesSchema = LMStudioClient.ResponseSchema(
        name: "themes_response",
        schemaJSON: """
        {
          "type": "object",
          "properties": {
            "themes": {
              "type": "array",
              "items": {
                "type": "object",
                "properties": {
                  "name":        {"type": "string"},
                  "description": {"type": "string"},
                  "artists":     {"type": "array", "items": {"type": "string"}}
                },
                "required": ["name", "description", "artists"]
              }
            }
          },
          "required": ["themes"]
        }
        """
    )

    private static let tracksSchema = LMStudioClient.ResponseSchema(
        name: "tracks_response",
        schemaJSON: """
        {
          "type": "object",
          "properties": {
            "tracks": {
              "type": "array",
              "items": {
                "type": "object",
                "properties": {
                  "title":  {"type": "string"},
                  "artist": {"type": "string"}
                },
                "required": ["title", "artist"]
              }
            }
          },
          "required": ["tracks"]
        }
        """
    )

    private static let trackIDsSchema = LMStudioClient.ResponseSchema(
        name: "track_ids_response",
        schemaJSON: """
        {
          "type": "object",
          "properties": {
            "ids": {"type": "array", "items": {"type": "integer"}}
          },
          "required": ["ids"]
        }
        """
    )

    // MARK: - Parsing

    private struct ThemesResponse: Decodable {
        let themes: [Theme]
        struct Theme: Decodable {
            let name: String
            let description: String
            let artists: [String]
        }
    }

    private struct TrackIDsResponse: Decodable {
        let ids: [Int]
    }

    private struct TracksResponse: Decodable {
        let tracks: [Track]
        struct Track: Decodable {
            let title: String
            let artist: String
        }
    }

    private static func parseThemes(_ raw: String) throws -> [ProposedTheme] {
        let decoded: ThemesResponse = try decodeWithFallback(raw, type: ThemesResponse.self)
        return decoded.themes.map {
            ProposedTheme(name: $0.name, description: $0.description, artists: $0.artists)
        }
    }

    private static func parseTracks(_ raw: String) throws -> TracksResponse {
        try decodeWithFallback(raw, type: TracksResponse.self)
    }

    private static func parseTrackIDs(_ raw: String) throws -> TrackIDsResponse {
        try decodeWithFallback(raw, type: TrackIDsResponse.self)
    }

    /// Generic JSON decoder with one fallback: try the raw string first; if that
    /// fails, slice from the first `{` to the last `}` and try again. Reasoning
    /// models occasionally bracket their JSON with prose despite the schema
    /// constraint — the slice rescues those cases.
    private static func decodeWithFallback<T: Decodable>(_ raw: String, type: T.Type) throws -> T {
        let decoder = JSONDecoder()
        if let data = raw.data(using: .utf8),
           let decoded = try? decoder.decode(T.self, from: data) {
            return decoded
        }
        // Reasoning models sometimes wrap JSON in prose or include trailing text.
        if let start = raw.firstIndex(of: "{"),
           let end = raw.lastIndex(of: "}") {
            let trimmed = String(raw[start...end])
            if let data = trimmed.data(using: .utf8),
               let decoded = try? decoder.decode(T.self, from: data) {
                return decoded
            }
        }
        throw ShowcaseError.invalidResponse("could not decode \(T.self) from response")
    }
}

/// One theme returned from pass 1 — a name + description + the LLM's chosen
/// roster of artists for it. Pass 2 takes one of these and generates the
/// actual track list.
struct ProposedTheme: Sendable, Hashable {
    let name: String
    let description: String
    let artists: [String]
}
