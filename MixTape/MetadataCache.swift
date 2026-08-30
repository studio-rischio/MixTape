import Foundation
import Observation

/// Orchestrates the artist-level MusicBrainz lookup that backs the Playlists tab's
/// LLM prompts. One-shot per artist: anything missing from the local cache gets
/// fetched (rate-limited to ~1 req/sec — MusicBrainz's anonymous-user budget).
///
/// Lifecycle:
/// 1. App launches; `MyDopplerView` calls `beginSync(libraryBundleURL:)` after it
///    successfully reads the library.
/// 2. We diff library artists against `MetadataCacheStore`; if anything's missing
///    we walk through them at 1/sec, calling `MusicBrainzClient`, upserting each
///    record into the cache.
/// 3. On completion we call `setInitialSyncComplete(true)`, which unlocks the
///    Playlists and Create tabs.
///
/// UI observes `phase` (state machine) and `cachedArtistCount` (running tally).
/// `@MainActor` so SwiftUI can read them safely.
@MainActor
@Observable
final class MetadataCache {
    static let shared = MetadataCache()

    /// Which half of the sync is running. They have very different shapes: artists
    /// go one-per-second through MusicBrainz's rate limit, tracks go in batches of
    /// 200 through ListenBrainz with no limit at all. Keeping them as separate
    /// stages means the banner's progress bar measures one thing at a time.
    enum Stage: Equatable, Sendable {
        case artists
        case recordings
    }

    /// State machine for the sync. The `syncing` case carries live progress so
    /// the SyncBanner can render a real-time progress bar + current-item label.
    enum Phase: Equatable, Sendable {
        case idle
        case syncing(stage: Stage, processed: Int, total: Int, current: String)
        case completed
        case failed(String)
        case cancelled
    }

    private(set) var phase: Phase = .idle
    private(set) var cachedArtistCount: Int = 0
    private(set) var cachedRecordingCount: Int = 0
    /// Reference to the running sync task so `cancel()` can stop it. `Task<Void, Never>`
    /// because failures are caught and stored in `phase` rather than thrown.
    private var syncTask: Task<Void, Never>?

    private static let initialSyncCompleteKey = "metadata_cache_initial_sync_complete"

    /// True once any sync run has completed end-to-end (across launches). Gates the
    /// Playlists and Create tabs — without a populated cache the LLM has nothing to
    /// work with.
    ///
    /// **Stored, not computed from `UserDefaults` on every read.** `@Observable` only
    /// tracks stored properties, so a computed accessor reading `UserDefaults` registers
    /// no dependency: a view gating on it would never re-render when the flag flipped
    /// mid-session, and would stay locked until the next launch rebuilt its body.
    /// `UserDefaults` remains the persistence layer — seeded here in `init`, written
    /// through `setInitialSyncComplete(_:)` — but the stored property is what the UI
    /// observes. Never write the key directly.
    private(set) var hasCompletedInitialSync: Bool

    /// Convenience for "is a sync currently in flight" — derived from `phase` so
    /// callers don't have to pattern-match the associated values themselves.
    var isSyncing: Bool {
        if case .syncing = phase { return true } else { return false }
    }

    private init() {
        hasCompletedInitialSync = UserDefaults.standard.bool(forKey: Self.initialSyncCompleteKey)
        // Best-effort refresh of `cachedArtistCount` at app launch so the Settings
        // UI shows the right number before any sync runs.
        Task { await refreshCachedCount() }
    }

    /// The only writer for `hasCompletedInitialSync`. Updates the observed property
    /// and its `UserDefaults` backing together so the two can't drift.
    private func setInitialSyncComplete(_ complete: Bool) {
        hasCompletedInitialSync = complete
        if complete {
            UserDefaults.standard.set(true, forKey: Self.initialSyncCompleteKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.initialSyncCompleteKey)
        }
    }

    /// Reloads `cachedArtistCount` from the store. Called at init and after every
    /// upsert during a sync so the Settings → MusicBrainz Cache row stays current.
    func refreshCachedCount() async {
        do {
            try await MetadataCacheStore.shared.open()
            cachedArtistCount = try await MetadataCacheStore.shared.cachedArtistCount()
            cachedRecordingCount = try await MetadataCacheStore.shared.cachedRecordingCount()
        } catch {
            Log.error("metadata cache count refresh failed: \(error.localizedDescription)", category: LogCategory.process)
        }
    }

    /// Kicks off a sync if one isn't already running. No-op if a sync is in flight.
    /// Internally diffs the library against the cache, so calling this every time
    /// the library loads is fine — it returns immediately when nothing's missing.
    func beginSync(libraryBundleURL: URL) {
        if isSyncing {
            Log.debug("metadata sync already running, ignoring beginSync", category: LogCategory.process)
            return
        }
        let url = libraryBundleURL
        syncTask = Task { [weak self] in
            await self?.runSync(libraryBundleURL: url)
        }
    }

    /// Cancels the running sync. The `runSync` body checks `Task.checkCancellation()`
    /// in the per-artist loop and `Task.sleep`'s 1-sec delay also throws on cancel,
    /// so the sync exits within ~1 second of this call.
    func cancel() {
        Log.info("user cancelled metadata sync", category: LogCategory.ui)
        syncTask?.cancel()
    }

    /// Cancels any in-flight sync, empties the cache, and clears the
    /// initial-sync-complete flag so the Showcase relocks until a fresh sync runs.
    func reset() async {
        Log.info("user requested metadata cache reset", category: LogCategory.ui)
        syncTask?.cancel()
        syncTask = nil
        do {
            try await MetadataCacheStore.shared.open()
            try await MetadataCacheStore.shared.deleteAll()
            cachedArtistCount = 0
            cachedRecordingCount = 0
            setInitialSyncComplete(false)
            phase = .idle
        } catch {
            Log.error("metadata cache reset failed: \(error.localizedDescription)", category: LogCategory.process)
        }
    }

    /// The actual sync loop. Runs in its own Task so the caller doesn't block.
    /// Sequence:
    /// 1. Read every artist name from Doppler.
    /// 2. Diff against `cachedArtistCanonicalNames()` — anything not in the cache
    ///    needs fetching.
    /// 3. For each missing artist: ask MusicBrainz, upsert the record (with `mbid:nil`
    ///    if we couldn't match — this prevents retrying the same dead lookup every
    ///    launch), update the running progress on `phase`, then `Task.sleep(1s)`
    ///    for the rate limit.
    /// 4. On completion, `setInitialSyncComplete(true)` → unlocks the Playlists and
    ///    Create tabs.
    ///
    /// `CancellationError` and other errors are caught and stored in `phase` rather
    /// than thrown — the Task type is `Task<Void, Never>`.
    private func runSync(libraryBundleURL: URL) async {
        do {
            try await MetadataCacheStore.shared.open()

            let lib = DopplerLibrary(bundleURL: libraryBundleURL)
            try await lib.openReadOnly()
            let allArtists = try await lib.allArtistNames()
            let allSongs = try await lib.allSongIdentities()
            await lib.close()

            let cachedCanonical = try await MetadataCacheStore.shared.cachedArtistCanonicalNames()
            let toFetch = allArtists.filter { !cachedCanonical.contains(Self.canonicalize($0)) }
            let total = toFetch.count

            Log.info(
                "metadata sync: \(allArtists.count) artists in library, \(cachedCanonical.count) cached, \(total) to fetch",
                category: LogCategory.process
            )

            if total == 0 {
                // Artists are done, but tracks may still be outstanding — a library
                // that grew since the last sync, or a cache from before track
                // lookups existed. Fall through to stage 2 rather than returning.
                setInitialSyncComplete(true)
                cachedArtistCount = try await MetadataCacheStore.shared.cachedArtistCount()
                try await syncRecordings(allSongs)
                phase = .completed
                return
            }

            phase = .syncing(stage: .artists, processed: 0, total: total, current: toFetch.first ?? "")
            let mb = MusicBrainzClient()

            for (index, name) in toFetch.enumerated() {
                try Task.checkCancellation()
                phase = .syncing(stage: .artists, processed: index, total: total, current: name)

                let canonical = Self.canonicalize(name)
                var record = MBArtistRecord(
                    canonicalName: canonical,
                    name: name,
                    mbid: nil,
                    disambiguation: nil,
                    type: nil,
                    country: nil,
                    tags: [],
                    lastFetchedAt: Date()
                )
                do {
                    if let result = try await mb.searchArtist(name: name) {
                        record = MBArtistRecord(
                            canonicalName: canonical,
                            name: name,
                            mbid: result.mbid,
                            disambiguation: result.disambiguation,
                            type: result.type,
                            country: result.country,
                            tags: result.tags,
                            lastFetchedAt: Date()
                        )
                        Log.info("MB matched \"\(name)\" -> \(result.mbid) (score \(result.score))", category: LogCategory.process)
                    } else {
                        Log.info("MB no confident match for \"\(name)\"", category: LogCategory.process)
                    }
                } catch {
                    // Cache the empty record so we don't retry every launch on a bad name.
                    Log.warning("MB lookup failed for \"\(name)\": \(error.localizedDescription)", category: LogCategory.process)
                }

                try await MetadataCacheStore.shared.upsertArtist(record)
                cachedArtistCount = try await MetadataCacheStore.shared.cachedArtistCount()

                // Anonymous MB rate limit is 1 req/sec averaged. Sleep after every request.
                try await Task.sleep(for: .seconds(1))
            }

            phase = .syncing(stage: .artists, processed: total, total: total, current: "")
            // Unlock the Playlists tab as soon as artists are cached — pass 1 only
            // needs artist metadata, so there's no reason to make the user wait for
            // stage 2 before they can generate anything.
            setInitialSyncComplete(true)
            Log.info("metadata sync: artists complete (\(total) fetched)", category: LogCategory.process)

            try await syncRecordings(allSongs)

            phase = .completed
            Log.info("metadata sync complete", category: LogCategory.process)
        } catch is CancellationError {
            phase = .cancelled
            Log.info("metadata sync cancelled", category: LogCategory.process)
        } catch {
            phase = .failed(error.localizedDescription)
            Log.error("metadata sync failed: \(error.localizedDescription)", category: LogCategory.process)
        }
    }

    /// Stage 2 of the sync: resolve every distinct `(artist, title)` in the library
    /// to a canonical MusicBrainz recording MBID, then fetch global listen counts
    /// for the ones that matched.
    ///
    /// Cache-first, like the artist stage: diff the library against
    /// `cachedRecordingKeys()` and only fetch what's missing. A warm cache makes
    /// this a no-op; a newly-added album costs one request.
    ///
    /// Unlike the artist stage this is **batched and unthrottled** — ListenBrainz's
    /// `acr-lookup` takes hundreds of pairs per request and imposes no rate limit,
    /// so ~3,000 tracks is a handful of requests rather than the ~50 minutes the
    /// same job would take through MusicBrainz's 1 req/sec endpoint. The small
    /// sleep between batches is politeness, not a documented requirement.
    ///
    /// Failures are logged and skipped rather than thrown: a bad batch shouldn't
    /// abort the whole sync, and anything skipped is simply retried next launch
    /// because it never got a cache row.
    private func syncRecordings(_ allSongs: [SongIdentity]) async throws {
        let cachedKeys = try await MetadataCacheStore.shared.cachedRecordingKeys()
        let toFetch = allSongs.filter {
            !cachedKeys.contains(
                MetadataCacheStore.recordingKey(artist: $0.canonicalArtist, title: $0.canonicalTitle)
            )
        }

        Log.info(
            "recording sync: \(allSongs.count) distinct tracks in library, \(cachedKeys.count) cached, \(toFetch.count) to fetch",
            category: LogCategory.process
        )
        guard !toFetch.isEmpty else {
            cachedRecordingCount = try await MetadataCacheStore.shared.cachedRecordingCount()
            return
        }

        let total = toFetch.count
        phase = .syncing(stage: .recordings, processed: 0, total: total, current: "")

        let lb = ListenBrainzClient()
        var processed = 0
        var matched = 0

        for batch in stride(from: 0, to: toFetch.count, by: ListenBrainzClient.batchSize) {
            try Task.checkCancellation()
            let slice = Array(toFetch[batch..<min(batch + ListenBrainzClient.batchSize, toFetch.count)])
            phase = .syncing(stage: .recordings, processed: processed, total: total, current: slice.first?.title ?? "")

            do {
                var matches = try await lb.lookupRecordings(slice.map { (artist: $0.artist, title: $0.title) })

                // Second pass for the misses: retry with packaging suffixes stripped
                // ("(2022 Mix)", "(Remaster)", "(featuring X)"). Only tracks that
                // both missed *and* have something to strip are retried, so this is
                // usually a small extra request and often none at all.
                let retryable: [(index: Int, artist: String, title: String)] = slice.enumerated().compactMap { offset, song in
                    guard matches[offset] == nil,
                          let stripped = ListenBrainzClient.strippedTitle(song.title)
                    else { return nil }
                    return (index: offset, artist: song.artist, title: stripped)
                }
                if !retryable.isEmpty {
                    let retried = try await lb.lookupRecordings(retryable.map { (artist: $0.artist, title: $0.title) })
                    // `retried` is keyed by position in the retry array; map back to
                    // the original slice offsets.
                    for (retryOffset, match) in retried {
                        matches[retryable[retryOffset].index] = match
                    }
                    Log.debug(
                        "recording sync: retried \(retryable.count) miss(es) with stripped titles, recovered \(retried.count)",
                        category: LogCategory.process
                    )
                }

                // Popularity is a second call keyed on the MBIDs we just resolved.
                //
                // If it fails, skip persisting the whole batch rather than writing
                // rows with NULL counts. The cache diff keys on row *presence*, so
                // a half-written row would never be revisited and the popularity
                // data would be silently lost until a full Reset Cache. Dropping
                // the batch costs one repeated `acr-lookup` next sync; both calls
                // hit ListenBrainz anyway, so if one is down the other likely is too.
                var popularity: [String: ListenBrainzClient.Popularity] = [:]
                let mbids = matches.values.map(\.recordingMBID)
                if !mbids.isEmpty {
                    do {
                        popularity = try await lb.popularity(recordingMBIDs: mbids)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        Log.warning(
                            "popularity lookup failed for a batch of \(mbids.count); not caching the batch so it retries: \(error.localizedDescription)",
                            category: LogCategory.process
                        )
                        processed += slice.count
                        continue
                    }
                }

                let now = Date()
                let records = slice.enumerated().map { offset, song -> MBRecordingRecord in
                    // No match means a negative-cache row: recorded as looked-up so
                    // the next sync skips it instead of asking again forever.
                    let match = matches[offset]
                    let pop = match.flatMap { popularity[$0.recordingMBID] }
                    return MBRecordingRecord(
                        canonicalArtist: song.canonicalArtist,
                        canonicalTitle: song.canonicalTitle,
                        artist: song.artist,
                        title: song.title,
                        recordingMBID: match?.recordingMBID,
                        artistMBID: match?.artistMBID,
                        releaseMBID: match?.releaseMBID,
                        releaseName: match?.releaseName,
                        listenCount: pop?.listenCount,
                        userCount: pop?.userCount,
                        lastFetchedAt: now
                    )
                }
                try await MetadataCacheStore.shared.upsertRecordings(records)
                matched += matches.count
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Skip the batch; no cache rows written, so it retries next launch.
                Log.warning("recording lookup failed for a batch of \(slice.count): \(error.localizedDescription)", category: LogCategory.process)
            }

            processed += slice.count
            phase = .syncing(stage: .recordings, processed: processed, total: total, current: "")
            cachedRecordingCount = try await MetadataCacheStore.shared.cachedRecordingCount()

            // Politeness pause. ListenBrainz documents no rate limit for these
            // endpoints, so this is deliberately short.
            try await Task.sleep(for: .milliseconds(250))
        }

        Log.info(
            "recording sync complete: \(matched)/\(total) matched to a canonical MBID",
            category: LogCategory.process
        )
    }

    /// Single canonicalization function used everywhere we key by artist name —
    /// the metadata cache, song lookups, theme-to-songs joining, etc. Lowercasing
    /// + trimming is the minimum we need to bridge minor formatting differences
    /// between Doppler's `ZRAWARTIST` strings and MusicBrainz's canonical names.
    static func canonicalize(_ name: String) -> String {
        name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Canonicalization that matches **SQLite's** `LOWER(TRIM(...))` rather than
    /// Swift's.
    ///
    /// SQLite's built-in `LOWER()` only maps ASCII A–Z; Swift's `lowercased()` is
    /// fully Unicode-aware. They disagree on any uppercase non-ASCII letter —
    /// `LOWER('BJÖRK')` is `bjÖrk` while `"BJÖRK".lowercased()` is `björk`. Use
    /// this whenever a Swift-side string has to match a key that was produced by
    /// SQL (the `mb_recording` primary key, `sampleSongsByArtist`'s grouping key,
    /// `SongIdentity.canonicalArtist`/`canonicalTitle`).
    ///
    /// `canonicalize(_:)` above remains correct for the artist cache, whose keys
    /// are written from Swift on both sides.
    static func sqlCanonicalize(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.map { ch in
            (ch >= "A" && ch <= "Z")
                ? Character(UnicodeScalar(ch.asciiValue! + 32))
                : ch
        })
    }
}
