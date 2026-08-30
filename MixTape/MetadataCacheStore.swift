import Foundation
import SQLite3

/// One cached artist from MusicBrainz. `mbid == nil` means "we looked this name
/// up and didn't get a confident match" — we still cache the attempt so we don't
/// retry failing names on every launch. `tags` are serialized as a JSON array
/// inside the single `tags TEXT` column (no separate tags table — YAGNI).
struct MBArtistRecord: Hashable, Sendable {
    let canonicalName: String
    let name: String
    let mbid: String?
    let disambiguation: String?
    let type: String?
    let country: String?
    let tags: [String]
    let lastFetchedAt: Date
}

/// One cached track identity from ListenBrainz, keyed by the canonicalized
/// `(artist, title)` pair rather than a Doppler `Z_PK` so it survives a song being
/// removed and re-added. `recordingMBID == nil` is a **cached negative** — the
/// track was looked up and ListenBrainz had no match — which is what stops every
/// sync retrying the same unmatched track forever.
///
/// `recordingMBID` is always the *canonical* recording MBID from `acr-lookup`.
/// See the note in `ListenBrainzClient` about why the MBID from a MusicBrainz
/// search is not interchangeable with it.
///
/// `listenCount`/`userCount` are global ListenBrainz figures, deliberately
/// distinct from the user's own play counts in `ZSONGPLAYHISTORY`.
struct MBRecordingRecord: Hashable, Sendable {
    let canonicalArtist: String
    let canonicalTitle: String
    let artist: String
    let title: String
    let recordingMBID: String?
    let artistMBID: String?
    let releaseMBID: String?
    let releaseName: String?
    let listenCount: Int?
    let userCount: Int?
    let lastFetchedAt: Date
}

/// Errors thrown by `MetadataCacheStore`. All surfaced with readable
/// `errorDescription` so the Settings UI can show them in a banner.
enum MetadataCacheError: LocalizedError {
    case notOpen
    case cannotOpen(String)
    case query(String)

    var errorDescription: String? {
        switch self {
        case .notOpen: return "Metadata cache database is not open."
        case .cannotOpen(let m): return "Couldn't open metadata cache: \(m)"
        case .query(let m): return "Metadata cache query failed: \(m)"
        }
    }
}

/// Local SQLite store for cached MusicBrainz artist metadata. Lives inside the
/// app's sandbox container at
/// `~/Library/Containers/<bundle-id>/Data/Library/Application Support/MixTape/metadata-cache.sqlite`.
/// Being in the container means no entitlements are required and the OS wipes it
/// cleanly if the app is deleted.
///
/// `actor` because the raw `sqlite3*` handle is single-threaded. Opened lazily
/// on first call to `open()`; stays open for the lifetime of the process.
actor MetadataCacheStore {
    static let shared = MetadataCacheStore()

    private var handle: OpaquePointer?

    private init() {}

    deinit {
        if let h = handle { sqlite3_close(h) }
    }

    /// Path to the cache file. Lazy so we don't create the directory until first
    /// access. Falls back to `NSTemporaryDirectory()` only if the Application
    /// Support lookup catastrophically fails (essentially never — but it's
    /// cheaper than crashing).
    private static var cacheDBURL: URL {
        let fm = FileManager.default
        let support = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = support.appendingPathComponent("MixTape", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("metadata-cache.sqlite")
    }

    /// Idempotent. Opens the cache DB with `SQLITE_OPEN_CREATE` so the file is
    /// created on first run, then ensures the schema is in place. Safe to call
    /// as a prelude to every cache operation — callers don't need to track open
    /// state themselves.
    func open() throws {
        guard handle == nil else { return }
        let path = Self.cacheDBURL.path
        Log.debug("opening metadata cache at \(path)", category: LogCategory.process)
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let opened = db else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "rc=\(rc)"
            if let opened = db { sqlite3_close(opened) }
            throw MetadataCacheError.cannotOpen(msg)
        }
        handle = opened
        try createSchema()
    }

    /// Creates the cache tables if they don't exist. Two flat tables — one row per
    /// canonicalized artist name, one per canonicalized `(artist, title)` pair.
    /// Schemas are flat because queries are simple (read-all and upsert-by-key);
    /// a proper relational shape would be overkill.
    ///
    /// `mb_recording` is keyed on the canonical pair rather than `ZSNRSONG.Z_PK`
    /// so the cache survives a song being removed and re-added — Core Data would
    /// hand the re-added row a new primary key, and we'd re-fetch for nothing.
    /// A row with `recording_mbid IS NULL` is a **cached negative**: ListenBrainz
    /// was asked and had no match, so don't ask again. Same trick as `mb_artist`
    /// storing `mbid: nil`.
    private func createSchema() throws {
        try exec("""
            CREATE TABLE IF NOT EXISTS mb_artist (
                canonical_name  TEXT PRIMARY KEY,
                name            TEXT NOT NULL,
                mbid            TEXT,
                disambiguation  TEXT,
                type            TEXT,
                country         TEXT,
                tags            TEXT,
                last_fetched_at REAL NOT NULL
            );
            """)
        try exec("""
            CREATE TABLE IF NOT EXISTS mb_recording (
                canonical_artist TEXT NOT NULL,
                canonical_title  TEXT NOT NULL,
                artist           TEXT NOT NULL,
                title            TEXT NOT NULL,
                recording_mbid   TEXT,
                artist_mbid      TEXT,
                release_mbid     TEXT,
                release_name     TEXT,
                listen_count     INTEGER,
                user_count       INTEGER,
                last_fetched_at  REAL NOT NULL,
                PRIMARY KEY (canonical_artist, canonical_title)
            );
            """)
    }

    private func exec(_ sql: String) throws {
        guard let db = handle else { throw MetadataCacheError.notOpen }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "exec rc=\(rc)"
            sqlite3_free(err)
            throw MetadataCacheError.query(msg)
        }
    }

    /// Returns the set of canonicalized artist names currently in the cache.
    /// Used by `MetadataCache.runSync` to diff against the Doppler library and
    /// figure out what still needs fetching — a `Set` gives O(1) membership checks.
    func cachedArtistCanonicalNames() throws -> Set<String> {
        guard let db = handle else { throw MetadataCacheError.notOpen }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT canonical_name FROM mb_artist", -1, &stmt, nil) == SQLITE_OK,
              let s = stmt
        else {
            throw MetadataCacheError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(s) }
        var result: Set<String> = []
        while sqlite3_step(s) == SQLITE_ROW {
            if let cstr = sqlite3_column_text(s, 0) {
                result.insert(String(cString: cstr))
            }
        }
        return result
    }

    /// Loads every cached artist record (for building the LLM pass-1 prompt).
    /// Decodes the `tags` JSON column back into `[String]`. Order by `name`
    /// (case-insensitive) for stable log output when nothing else cares.
    func loadAllArtistRecords() throws -> [MBArtistRecord] {
        guard let db = handle else { throw MetadataCacheError.notOpen }
        let sql = """
            SELECT canonical_name, name, mbid, disambiguation, type, country, tags, last_fetched_at
            FROM mb_artist
            ORDER BY name COLLATE NOCASE
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw MetadataCacheError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(s) }

        var rows: [MBArtistRecord] = []
        while sqlite3_step(s) == SQLITE_ROW {
            let tagsJSON = stringColumn(s, 6) ?? "[]"
            let tags: [String] = (try? JSONDecoder().decode([String].self, from: Data(tagsJSON.utf8))) ?? []
            rows.append(MBArtistRecord(
                canonicalName: stringColumn(s, 0) ?? "",
                name: stringColumn(s, 1) ?? "",
                mbid: stringColumn(s, 2),
                disambiguation: stringColumn(s, 3),
                type: stringColumn(s, 4),
                country: stringColumn(s, 5),
                tags: tags,
                lastFetchedAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 7))
            ))
        }
        return rows
    }

    private func stringColumn(_ stmt: OpaquePointer, _ idx: Int32) -> String? {
        guard let cstr = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: cstr)
    }

    /// Fast `COUNT(*)` — powers the live counter in the SyncBanner and Settings.
    func cachedArtistCount() throws -> Int {
        guard let db = handle else { throw MetadataCacheError.notOpen }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM mb_artist", -1, &stmt, nil) == SQLITE_OK,
              let s = stmt
        else {
            throw MetadataCacheError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(s, 0))
    }

    /// Fast `COUNT(*)` over cached tracks. Counts negative-cache rows too — the
    /// point is "how much of the library have we asked about", not "how much matched".
    func cachedRecordingCount() throws -> Int {
        guard let db = handle else { throw MetadataCacheError.notOpen }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM mb_recording", -1, &stmt, nil) == SQLITE_OK,
              let s = stmt
        else {
            throw MetadataCacheError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(s, 0))
    }

    /// Empties both cache tables. Used by Settings → "Reset Cache" when the user
    /// wants to re-run MusicBrainz lookups (e.g., after we've improved the
    /// disambiguation heuristic).
    func deleteAll() throws {
        try exec("DELETE FROM mb_artist;")
        try exec("DELETE FROM mb_recording;")
        Log.info("metadata cache cleared", category: LogCategory.process)
    }

    /// The `(canonical_artist, canonical_title)` pairs already looked up. Includes
    /// negative-cache rows, which is the whole point — a track ListenBrainz has no
    /// match for must count as "done" or every sync would retry it forever.
    /// Joined with `\u{1}` because that byte can't appear in a canonicalized name.
    func cachedRecordingKeys() throws -> Set<String> {
        guard let db = handle else { throw MetadataCacheError.notOpen }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT canonical_artist, canonical_title FROM mb_recording", -1, &stmt, nil) == SQLITE_OK,
              let s = stmt
        else {
            throw MetadataCacheError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(s) }
        var result: Set<String> = []
        while sqlite3_step(s) == SQLITE_ROW {
            let artist = stringColumn(s, 0) ?? ""
            let title = stringColumn(s, 1) ?? ""
            result.insert(Self.recordingKey(artist: artist, title: title))
        }
        return result
    }

    /// Cache key for one track. Kept here so the sync and the store can't drift.
    static func recordingKey(artist: String, title: String) -> String {
        "\(artist)\u{1}\(title)"
    }

    /// Global listen counts keyed by `recordingKey`, for tracks that have one.
    /// Powers the familiarity filter — rows with no count are simply absent, and
    /// callers treat "absent" as unknown rather than as zero.
    func popularityByKey() throws -> [String: Int] {
        guard let db = handle else { throw MetadataCacheError.notOpen }
        let sql = "SELECT canonical_artist, canonical_title, listen_count FROM mb_recording WHERE listen_count IS NOT NULL"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw MetadataCacheError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(s) }
        var result: [String: Int] = [:]
        while sqlite3_step(s) == SQLITE_ROW {
            let artist = stringColumn(s, 0) ?? ""
            let title = stringColumn(s, 1) ?? ""
            result[Self.recordingKey(artist: artist, title: title)] = Int(sqlite3_column_int64(s, 2))
        }
        return result
    }

    /// `recordingKey` → `recording_mbid`. Queried directly rather than inverted
    /// from `recordingKeysByMBID()`: several library tracks can share one MBID
    /// (the stripped-title retry deliberately maps "Song (2011 Remaster)" onto
    /// plain "Song"), and inverting a dictionary keyed on the MBID would keep only
    /// one of them — so looking up a seed by the variant that lost would fail.
    func mbidsByRecordingKey() throws -> [String: String] {
        guard let db = handle else { throw MetadataCacheError.notOpen }
        let sql = "SELECT canonical_artist, canonical_title, recording_mbid FROM mb_recording WHERE recording_mbid IS NOT NULL"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw MetadataCacheError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(s) }
        var result: [String: String] = [:]
        while sqlite3_step(s) == SQLITE_ROW {
            let artist = stringColumn(s, 0) ?? ""
            let title = stringColumn(s, 1) ?? ""
            guard let mbid = stringColumn(s, 2) else { continue }
            result[Self.recordingKey(artist: artist, title: title)] = mbid
        }
        return result
    }

    /// `recording_mbid` → `recordingKey`, for tracks that matched. Lets the
    /// similarity walk turn MBIDs coming back from ListenBrainz into tracks the
    /// user actually owns, without a per-track database lookup.
    ///
    /// Collapsing several library tracks that share an MBID down to one is
    /// *desirable* here — a "more like this" playlist shouldn't contain both the
    /// original and its remaster. The reverse direction can't collapse, which is
    /// why `mbidsByRecordingKey()` runs its own query.
    func recordingKeysByMBID() throws -> [String: String] {
        guard let db = handle else { throw MetadataCacheError.notOpen }
        let sql = "SELECT recording_mbid, canonical_artist, canonical_title FROM mb_recording WHERE recording_mbid IS NOT NULL"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw MetadataCacheError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(s) }
        var result: [String: String] = [:]
        while sqlite3_step(s) == SQLITE_ROW {
            guard let mbid = stringColumn(s, 0) else { continue }
            let artist = stringColumn(s, 1) ?? ""
            let title = stringColumn(s, 2) ?? ""
            result[mbid] = Self.recordingKey(artist: artist, title: title)
        }
        return result
    }


    /// Upserts a batch of recording rows inside one transaction. Batched because a
    /// sync writes thousands of rows and a commit per row is dramatically slower.
    func upsertRecordings(_ records: [MBRecordingRecord]) throws {
        guard let db = handle else { throw MetadataCacheError.notOpen }
        guard !records.isEmpty else { return }
        let sql = """
            INSERT INTO mb_recording
                (canonical_artist, canonical_title, artist, title,
                 recording_mbid, artist_mbid, release_mbid, release_name,
                 listen_count, user_count, last_fetched_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(canonical_artist, canonical_title) DO UPDATE SET
                artist          = excluded.artist,
                title           = excluded.title,
                recording_mbid  = excluded.recording_mbid,
                artist_mbid     = excluded.artist_mbid,
                release_mbid    = excluded.release_mbid,
                release_name    = excluded.release_name,
                listen_count    = excluded.listen_count,
                user_count      = excluded.user_count,
                last_fetched_at = excluded.last_fetched_at
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw MetadataCacheError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(s) }

        try exec("BEGIN IMMEDIATE TRANSACTION;")
        do {
            for record in records {
                sqlite3_reset(s)
                sqlite3_clear_bindings(s)
                sqlite3_bind_text(s, 1, record.canonicalArtist, -1, Self.transient)
                sqlite3_bind_text(s, 2, record.canonicalTitle, -1, Self.transient)
                sqlite3_bind_text(s, 3, record.artist, -1, Self.transient)
                sqlite3_bind_text(s, 4, record.title, -1, Self.transient)
                bindOptional(s, 5, record.recordingMBID)
                bindOptional(s, 6, record.artistMBID)
                bindOptional(s, 7, record.releaseMBID)
                bindOptional(s, 8, record.releaseName)
                if let listens = record.listenCount {
                    sqlite3_bind_int64(s, 9, Int64(listens))
                } else {
                    sqlite3_bind_null(s, 9)
                }
                if let users = record.userCount {
                    sqlite3_bind_int64(s, 10, Int64(users))
                } else {
                    sqlite3_bind_null(s, 10)
                }
                sqlite3_bind_double(s, 11, record.lastFetchedAt.timeIntervalSince1970)

                guard sqlite3_step(s) == SQLITE_DONE else {
                    throw MetadataCacheError.query(String(cString: sqlite3_errmsg(db)))
                }
            }
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// Inserts or updates an artist record, keyed by `canonicalName`. Uses
    /// SQLite's `ON CONFLICT ... DO UPDATE` so callers don't have to do their
    /// own exists-check. Called once per artist during a sync.
    func upsertArtist(_ record: MBArtistRecord) throws {
        guard let db = handle else { throw MetadataCacheError.notOpen }
        let sql = """
            INSERT INTO mb_artist (canonical_name, name, mbid, disambiguation, type, country, tags, last_fetched_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(canonical_name) DO UPDATE SET
                name            = excluded.name,
                mbid            = excluded.mbid,
                disambiguation  = excluded.disambiguation,
                type            = excluded.type,
                country         = excluded.country,
                tags            = excluded.tags,
                last_fetched_at = excluded.last_fetched_at
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw MetadataCacheError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(s) }

        sqlite3_bind_text(s, 1, record.canonicalName, -1, Self.transient)
        sqlite3_bind_text(s, 2, record.name, -1, Self.transient)
        bindOptional(s, 3, record.mbid)
        bindOptional(s, 4, record.disambiguation)
        bindOptional(s, 5, record.type)
        bindOptional(s, 6, record.country)
        let tagsJSON = (try? String(data: JSONEncoder().encode(record.tags), encoding: .utf8)) ?? "[]"
        sqlite3_bind_text(s, 7, tagsJSON, -1, Self.transient)
        sqlite3_bind_double(s, 8, record.lastFetchedAt.timeIntervalSince1970)

        guard sqlite3_step(s) == SQLITE_DONE else {
            throw MetadataCacheError.query(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func bindOptional(_ stmt: OpaquePointer, _ idx: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, idx, value, -1, Self.transient)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    private static let transient = unsafeBitCast(
        OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self
    )
}
