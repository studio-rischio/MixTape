import Foundation
import SQLite3

/// A Doppler playlist row, keyed by Core Data's `Z_PK`. `songCount` is computed
/// via a `LEFT JOIN` against the `Z_7SONGS` join table.
struct Playlist: Identifiable, Hashable, Sendable {
    let id: Int64
    let name: String
    let songCount: Int
}

/// A bare-bones song row used by free-text search (`findSongs(matching:)`).
struct Song: Identifiable, Hashable, Sendable {
    let id: Int64
    let title: String
    let artist: String?
}

/// A song with display-friendly metadata used by the My Doppler stat panels and
/// by Showcase track resolution (`findSong(title:artist:)`). `dateAdded` is the
/// converted-to-Swift `ZSNRSONG.ZDATEADDED` (Core Data reference date — see
/// `coreDataDate` below). `playCount` is only populated by `mostPlayedSongs`.
struct SongRow: Identifiable, Hashable, Sendable {
    let id: Int64
    let title: String
    let artist: String?
    let album: String?
    let dateAdded: Date?
    let playCount: Int?
}

/// One candidate track offered to the LLM in the pass-2 prompt: a title plus the
/// `ZSNRSONG.Z_PK` it came from. Keeping the ID attached is what lets the prompt
/// number the candidates and accept indices back instead of re-typed title strings.
struct SongCandidate: Identifiable, Hashable, Sendable {
    let id: Int64
    let title: String
    /// `LOWER(TRIM(ZNAME))` straight from SQLite. Carried rather than recomputed
    /// in Swift because SQLite's `LOWER()` is ASCII-only while Swift's
    /// `lowercased()` is Unicode-aware — they disagree on any uppercase non-ASCII
    /// letter ("BJÖRK" → `bjÖrk` vs `björk`), and the popularity cache is keyed
    /// on the SQL form.
    let canonicalTitle: String
}

/// A distinct `(artist, title)` in the library, in both display and canonical
/// form. The canonical pair is the `mb_recording` cache key; the display pair is
/// what gets sent to ListenBrainz for matching.
struct SongIdentity: Hashable, Sendable {
    let canonicalArtist: String
    let canonicalTitle: String
    let artist: String
    let title: String
    /// One representative `ZSNRSONG.Z_PK` for this canonical pair. The same song
    /// can exist on several albums; any of them plays the same music, so the
    /// similarity walk just needs one to put in a playlist.
    let songID: Int64
}

/// File-system location for a single song. Resolved out of `ZSNRSONG.ZBOOKMARK`,
/// which Doppler stores as a small "EBMK" envelope (the watched-folder root the
/// song was imported under) wrapped around a standard Foundation bookmark
/// pointing at the audio file. `relativePath` is the absolute path with the
/// library root stripped — the format the .m3u export wants
/// (`Artist/Album/01 Song.mp3`). All three fields are `nil`-tolerant: a song with
/// no bookmark, or one whose bookmark we can't resolve, simply gets nil entries.
struct SongLocation: Sendable, Hashable {
    let id: Int64
    let libraryRoot: String?
    let absolutePath: String?

    var relativePath: String? {
        guard let absolutePath, let libraryRoot, !libraryRoot.isEmpty else {
            return absolutePath
        }
        let prefix = libraryRoot.hasSuffix("/") ? libraryRoot : libraryRoot + "/"
        if absolutePath.hasPrefix(prefix) {
            return String(absolutePath.dropFirst(prefix.count))
        }
        return absolutePath
    }
}

/// Library-wide counts shown as the four stat tiles at the top of My Doppler.
/// `zero` is the placeholder used while the first query is in flight.
struct LibraryCounts: Hashable, Sendable {
    let songs: Int
    let artists: Int
    let albums: Int
    let playlists: Int

    static let zero = LibraryCounts(songs: 0, artists: 0, albums: 0, playlists: 0)
}

/// Errors thrown by `DopplerLibrary`. All `LocalizedError`-conforming so they
/// surface with their `errorDescription` in alerts and the debug log.
enum DopplerLibraryError: LocalizedError {
    case bookmarkAccessDenied
    case cannotOpen(String)
    case query(String)

    var errorDescription: String? {
        switch self {
        case .bookmarkAccessDenied:
            return "Lost permission to read the Doppler library — please re-select it."
        case .cannotOpen(let msg):
            return "Couldn't open Doppler library: \(msg)"
        case .query(let msg):
            return "Database query failed: \(msg)"
        }
    }
}

/// **Read-only** access to the Doppler library SQLite store. Mutations go through
/// `DopplerLibraryWriter` instead — splitting the two surfaces makes the dangerous
/// write path explicit.
///
/// `actor` because the underlying `sqlite3*` handle is single-threaded by default
/// (we open with `SQLITE_OPEN_NOMUTEX`). Concurrent calls are serialized by the
/// actor runtime.
///
/// Lifecycle: instantiate per-operation (or per-load-cycle), `openReadOnly()`,
/// run queries, then `close()`. The actor holds a security-scoped resource lock
/// on the library bundle while the handle is open and releases it in `close()`
/// (and as a safety net in `deinit`).
actor DopplerLibrary {
    private let bundleURL: URL
    /// Opaque pointer to the C `sqlite3*`. `nil` between init and `openReadOnly()`,
    /// and after `close()`.
    private var handle: OpaquePointer?
    /// Tracks whether `startAccessingSecurityScopedResource()` succeeded so `close()`
    /// can pair it with the matching stop call. macOS requires balanced calls; an
    /// extra stop is harmless but a missed one leaks the scope until process exit.
    private var holdingScope = false

    init(bundleURL: URL) {
        self.bundleURL = bundleURL
    }

    deinit {
        // Belt-and-suspenders cleanup if the caller forgets to `close()`. Synchronous
        // in deinit by necessity — actor-isolated cleanup isn't allowed here.
        if let h = handle { sqlite3_close(h) }
        if holdingScope { bundleURL.stopAccessingSecurityScopedResource() }
    }

    /// Idempotent. Acquires the security-scoped resource lock (we hold it for the
    /// entire open lifetime so SQLite's mmap can read freely), then opens the DB
    /// inside the bundle with `SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX`. Throws
    /// `bookmarkAccessDenied` if the bookmark has been revoked, or `cannotOpen` on
    /// any SQLite error.
    func openReadOnly() throws {
        guard handle == nil else { return }

        guard bundleURL.startAccessingSecurityScopedResource() else {
            Log.error("could not start security scope on \(bundleURL.lastPathComponent)", category: LogCategory.doppler)
            throw DopplerLibraryError.bookmarkAccessDenied
        }
        holdingScope = true

        let dbPath = DopplerLibraryLocation.dbFile(in: bundleURL).path
        Log.debug("opening sqlite (read-only) at \(dbPath)", category: LogCategory.doppler)
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(dbPath, &db, flags, nil)
        guard rc == SQLITE_OK, let opened = db else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "rc=\(rc)"
            if let opened = db { sqlite3_close(opened) }
            bundleURL.stopAccessingSecurityScopedResource()
            holdingScope = false
            Log.error("sqlite open failed: \(msg)", category: LogCategory.doppler)
            throw DopplerLibraryError.cannotOpen(msg)
        }
        handle = opened
        Log.info("opened doppler library", category: LogCategory.doppler)
    }

    /// Closes the SQLite handle and releases the security-scoped resource lock.
    /// Idempotent — safe to call from a `defer` block alongside the natural close
    /// at the end of a function.
    func close() {
        if let h = handle {
            sqlite3_close(h)
            handle = nil
            Log.debug("closed sqlite handle", category: LogCategory.doppler)
        }
        if holdingScope {
            bundleURL.stopAccessingSecurityScopedResource()
            holdingScope = false
        }
    }

    /// Returns every playlist in the library with its track count. Sorted alphabetically
    /// using `COLLATE NOCASE`. Backs both the My Doppler "Playlists" panel and the
    /// `mostPlayedSongs` UI's playlist count.
    func listPlaylists() throws -> [Playlist] {
        let db = try requireOpen()
        let started = Date()
        let sql = """
            SELECT p.Z_PK, p.ZNAME, COUNT(s.Z_11SONGS) AS n_songs
            FROM ZPERSISTENTPLAYLIST p
            LEFT JOIN Z_7SONGS s ON s.Z_7PLAYLISTS = p.Z_PK
            GROUP BY p.Z_PK
            ORDER BY p.ZNAME COLLATE NOCASE
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            Log.error("listPlaylists prepare failed: \(msg)", category: LogCategory.doppler)
            throw DopplerLibraryError.query(msg)
        }
        defer { sqlite3_finalize(s) }

        var rows: [Playlist] = []
        while sqlite3_step(s) == SQLITE_ROW {
            rows.append(Playlist(
                id: sqlite3_column_int64(s, 0),
                name: stringColumn(s, 1) ?? "(unnamed)",
                songCount: Int(sqlite3_column_int64(s, 2))
            ))
        }
        Log.info("listPlaylists -> \(rows.count) rows in \(elapsedMs(started))ms", category: LogCategory.doppler)
        return rows
    }

    /// Free-text search over song titles and artist strings. Currently unused by
    /// the UI (kept for parity with the Python prototype + future search bar).
    func findSongs(matching needle: String) throws -> [Song] {
        let db = try requireOpen()
        let started = Date()
        Log.debug("findSongs query=\"\(needle)\"", category: LogCategory.doppler)
        let sql = """
            SELECT Z_PK, ZNAME, ZRAWARTIST
            FROM ZSNRSONG
            WHERE (ZNAME LIKE ? ESCAPE '\\' OR ZRAWARTIST LIKE ? ESCAPE '\\')
              AND (ZISMISSING IS NULL OR ZISMISSING = 0)
              AND ZNAME IS NOT NULL AND TRIM(ZNAME) != ''
              AND ZRAWARTIST IS NOT NULL AND TRIM(ZRAWARTIST) != ''
            ORDER BY ZRAWARTIST COLLATE NOCASE, ZNAME COLLATE NOCASE
            LIMIT 100
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            Log.error("findSongs prepare failed: \(msg)", category: LogCategory.doppler)
            throw DopplerLibraryError.query(msg)
        }
        defer { sqlite3_finalize(s) }

        // Escape LIKE metacharacters, or "AC_DC" silently matches "AC/DC" and a
        // query containing "%" matches nearly everything.
        let escaped = needle
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let pattern = "%\(escaped)%"
        sqlite3_bind_text(s, 1, pattern, -1, Self.transientDestructor)
        sqlite3_bind_text(s, 2, pattern, -1, Self.transientDestructor)

        var rows: [Song] = []
        while sqlite3_step(s) == SQLITE_ROW {
            rows.append(Song(
                id: sqlite3_column_int64(s, 0),
                title: stringColumn(s, 1) ?? "(untitled)",
                artist: stringColumn(s, 2)
            ))
        }
        Log.info("findSongs \"\(needle)\" -> \(rows.count) rows in \(elapsedMs(started))ms", category: LogCategory.doppler)
        return rows
    }

    /// Single-statement aggregate of all four counts (songs/artists/albums/playlists).
    /// Cheap — runs in well under 1 ms on a typical library. Powers the My Doppler
    /// stat tiles row.
    func libraryCounts() throws -> LibraryCounts {
        let db = try requireOpen()
        let started = Date()
        let sql = """
            SELECT
              (SELECT COUNT(*) FROM ZSNRSONG)              AS songs,
              (SELECT COUNT(*) FROM ZSNRARTIST)            AS artists,
              (SELECT COUNT(*) FROM ZSNRALBUM)             AS albums,
              (SELECT COUNT(*) FROM ZPERSISTENTPLAYLIST)   AS playlists
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            Log.error("libraryCounts prepare failed: \(msg)", category: LogCategory.doppler)
            throw DopplerLibraryError.query(msg)
        }
        defer { sqlite3_finalize(s) }
        guard sqlite3_step(s) == SQLITE_ROW else {
            throw DopplerLibraryError.query("libraryCounts returned no row")
        }
        let counts = LibraryCounts(
            songs: Int(sqlite3_column_int64(s, 0)),
            artists: Int(sqlite3_column_int64(s, 1)),
            albums: Int(sqlite3_column_int64(s, 2)),
            playlists: Int(sqlite3_column_int64(s, 3))
        )
        Log.info(
            "libraryCounts -> \(counts.songs) songs, \(counts.artists) artists, \(counts.albums) albums, \(counts.playlists) playlists in \(elapsedMs(started))ms",
            category: LogCategory.doppler
        )
        return counts
    }

    /// Most recently added songs (by `ZDATEADDED DESC`), up to `limit`. Excludes
    /// rows where Doppler has flagged the file as missing. Joins `ZSNRALBUM` for
    /// the album name. Powers the My Doppler "Recently Added" panel.
    func recentlyAddedSongs(limit: Int = 10) throws -> [SongRow] {
        let db = try requireOpen()
        let started = Date()
        let sql = """
            SELECT s.Z_PK, s.ZNAME, s.ZRAWARTIST, a.ZNAME, s.ZDATEADDED
            FROM ZSNRSONG s
            LEFT JOIN ZSNRALBUM a ON a.Z_PK = s.ZALBUM
            WHERE (s.ZISMISSING IS NULL OR s.ZISMISSING = 0) AND s.ZDATEADDED IS NOT NULL
            ORDER BY s.ZDATEADDED DESC
            LIMIT ?
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            Log.error("recentlyAddedSongs prepare failed: \(msg)", category: LogCategory.doppler)
            throw DopplerLibraryError.query(msg)
        }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_int64(s, 1, Int64(limit))

        var rows: [SongRow] = []
        while sqlite3_step(s) == SQLITE_ROW {
            rows.append(SongRow(
                id: sqlite3_column_int64(s, 0),
                title: stringColumn(s, 1) ?? "(untitled)",
                artist: stringColumn(s, 2),
                album: stringColumn(s, 3),
                dateAdded: coreDataDate(s, 4),
                playCount: nil
            ))
        }
        Log.info("recentlyAddedSongs(limit: \(limit)) -> \(rows.count) rows in \(elapsedMs(started))ms", category: LogCategory.doppler)
        return rows
    }

    /// Returns album names grouped by canonicalized artist name (joined via
    /// `ZSNRALBUM.ZARTIST` → `ZSNRARTIST.ZNAME`). Used by the Showcase pass-1 prompt.
    func albumsByArtist() throws -> [String: [String]] {
        let db = try requireOpen()
        let started = Date()
        let sql = """
            SELECT
                LOWER(TRIM(ar.ZNAME)) AS canonical_artist,
                a.ZNAME              AS album_name
            FROM ZSNRALBUM a
            JOIN ZSNRARTIST ar ON ar.Z_PK = a.ZARTIST
            WHERE a.ZNAME IS NOT NULL
              AND ar.ZNAME IS NOT NULL
              AND TRIM(ar.ZNAME) != ''
            ORDER BY ar.ZNAME COLLATE NOCASE, COALESCE(a.ZRELEASEYEAR, 9999)
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw DopplerLibraryError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(s) }

        var result: [String: [String]] = [:]
        while sqlite3_step(s) == SQLITE_ROW {
            let canonicalArtist = stringColumn(s, 0) ?? ""
            let albumName = stringColumn(s, 1) ?? ""
            result[canonicalArtist, default: []].append(albumName)
        }
        let total = result.values.reduce(0) { $0 + $1.count }
        Log.info("albumsByArtist -> \(total) rows across \(result.count) artists in \(elapsedMs(started))ms", category: LogCategory.doppler)
        return result
    }

    /// For each distinct artist (keyed by canonicalized `ZRAWARTIST`), returns up to N
    /// representative songs sorted by `ZDATEADDED` descending. Used by the Showcase
    /// prompt so the LLM picks from real tracks instead of guessing the discography.
    ///
    /// Carries `Z_PK` alongside the title because the pass-2 prompt numbers these
    /// candidates and asks the LLM to reply with indices — the index maps straight
    /// back to a song ID, so there's no title string to re-resolve afterwards.
    func sampleSongsByArtist(perArtistLimit: Int = 8) throws -> [String: [SongCandidate]] {
        let db = try requireOpen()
        let started = Date()
        let sql = """
            WITH ranked AS (
                SELECT
                    LOWER(TRIM(s.ZRAWARTIST)) AS canonical_artist,
                    s.Z_PK AS song_id,
                    s.ZNAME AS title,
                    LOWER(TRIM(s.ZNAME)) AS canonical_title,
                    ROW_NUMBER() OVER (
                        PARTITION BY LOWER(TRIM(s.ZRAWARTIST))
                        ORDER BY s.ZDATEADDED DESC, s.Z_PK DESC
                    ) AS rn
                FROM ZSNRSONG s
                WHERE s.ZNAME IS NOT NULL
                  AND s.ZRAWARTIST IS NOT NULL
                  AND TRIM(s.ZRAWARTIST) != ''
                  AND (s.ZISMISSING IS NULL OR s.ZISMISSING = 0)
            )
            SELECT canonical_artist, song_id, title, canonical_title FROM ranked WHERE rn <= ? ORDER BY canonical_artist, rn
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw DopplerLibraryError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_int64(s, 1, Int64(perArtistLimit))

        var result: [String: [SongCandidate]] = [:]
        var totalRows = 0
        while sqlite3_step(s) == SQLITE_ROW {
            let canonicalArtist = stringColumn(s, 0) ?? ""
            let songID = sqlite3_column_int64(s, 1)
            let title = stringColumn(s, 2) ?? ""
            let canonicalTitle = stringColumn(s, 3) ?? ""
            result[canonicalArtist, default: []].append(
                SongCandidate(id: songID, title: title, canonicalTitle: canonicalTitle)
            )
            totalRows += 1
        }
        Log.info(
            "sampleSongsByArtist(\(perArtistLimit)) -> \(totalRows) rows across \(result.count) artists in \(elapsedMs(started))ms",
            category: LogCategory.doppler
        )
        return result
    }

    /// Looks up a song by exact title (case-insensitive), optionally constrained by artist.
    /// Used by the Showcase to resolve LLM-named tracks back to Doppler `Z_PK`s.
    func findSong(title: String, artist: String?) throws -> SongRow? {
        let db = try requireOpen()
        var sql = """
            SELECT s.Z_PK, s.ZNAME, s.ZRAWARTIST, a.ZNAME, s.ZDATEADDED
            FROM ZSNRSONG s
            LEFT JOIN ZSNRALBUM a ON a.Z_PK = s.ZALBUM
            WHERE LOWER(TRIM(s.ZNAME)) = LOWER(TRIM(?))
            """
        if artist != nil {
            sql += " AND LOWER(TRIM(s.ZRAWARTIST)) = LOWER(TRIM(?))"
        }
        sql += " LIMIT 1"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw DopplerLibraryError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(s) }

        sqlite3_bind_text(s, 1, title, -1, Self.transientDestructor)
        if let artist {
            sqlite3_bind_text(s, 2, artist, -1, Self.transientDestructor)
        }

        guard sqlite3_step(s) == SQLITE_ROW else { return nil }
        return SongRow(
            id: sqlite3_column_int64(s, 0),
            title: stringColumn(s, 1) ?? title,
            artist: stringColumn(s, 2),
            album: stringColumn(s, 3),
            dateAdded: coreDataDate(s, 4),
            playCount: nil
        )
    }

    /// Every distinct `(artist, title)` in the library, with the canonical forms
    /// used as the `mb_recording` cache key. Distinct on the canonical pair, not
    /// on `Z_PK` — the same song on two albums is one lookup, not two.
    ///
    /// Excludes `ZISMISSING` rows for the same reason every other prompt-facing
    /// query does: there's no point resolving metadata for a file that's gone.
    func allSongIdentities() throws -> [SongIdentity] {
        let db = try requireOpen()
        let started = Date()
        let sql = """
            SELECT
                LOWER(TRIM(s.ZRAWARTIST)) AS canonical_artist,
                LOWER(TRIM(s.ZNAME))      AS canonical_title,
                MIN(s.ZRAWARTIST)         AS artist,
                MIN(s.ZNAME)              AS title,
                MIN(s.Z_PK)               AS song_id
            FROM ZSNRSONG s
            WHERE s.ZNAME IS NOT NULL
              AND TRIM(s.ZNAME) != ''
              AND s.ZRAWARTIST IS NOT NULL
              AND TRIM(s.ZRAWARTIST) != ''
              AND (s.ZISMISSING IS NULL OR s.ZISMISSING = 0)
            GROUP BY canonical_artist, canonical_title
            ORDER BY canonical_artist, canonical_title
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            Log.error("allSongIdentities prepare failed: \(msg)", category: LogCategory.doppler)
            throw DopplerLibraryError.query(msg)
        }
        defer { sqlite3_finalize(s) }
        var rows: [SongIdentity] = []
        while sqlite3_step(s) == SQLITE_ROW {
            rows.append(
                SongIdentity(
                    canonicalArtist: stringColumn(s, 0) ?? "",
                    canonicalTitle: stringColumn(s, 1) ?? "",
                    artist: stringColumn(s, 2) ?? "",
                    title: stringColumn(s, 3) ?? "",
                    songID: sqlite3_column_int64(s, 4)
                )
            )
        }
        Log.info("allSongIdentities -> \(rows.count) distinct tracks in \(elapsedMs(started))ms", category: LogCategory.doppler)
        return rows
    }

    /// Every artist's display name (from `ZSNRARTIST.ZNAME`), sorted by Doppler's
    /// own `ZSORTINGNAME` so the order matches the app. Used by `MetadataCache` to
    /// diff against the local cache and figure out what to fetch from MusicBrainz.
    func allArtistNames() throws -> [String] {
        let db = try requireOpen()
        let started = Date()
        let sql = """
            SELECT ZNAME FROM ZSNRARTIST
            WHERE ZNAME IS NOT NULL AND TRIM(ZNAME) != ''
            ORDER BY ZSORTINGNAME COLLATE NOCASE
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            Log.error("allArtistNames prepare failed: \(msg)", category: LogCategory.doppler)
            throw DopplerLibraryError.query(msg)
        }
        defer { sqlite3_finalize(s) }
        var rows: [String] = []
        while sqlite3_step(s) == SQLITE_ROW {
            if let cstr = sqlite3_column_text(s, 0) {
                rows.append(String(cString: cstr))
            }
        }
        Log.info("allArtistNames -> \(rows.count) in \(elapsedMs(started))ms", category: LogCategory.doppler)
        return rows
    }

    /// Top-N songs by play count, computed by `COUNT(*) GROUP BY ZSONG` against
    /// `ZSONGPLAYHISTORY` (which is an event log, one row per play). Powers the
    /// My Doppler "Most Played" panel. Sparse for users who haven't been on Doppler
    /// long — we surface a friendly empty hint in that case.
    func mostPlayedSongs(limit: Int = 10) throws -> [SongRow] {
        let db = try requireOpen()
        let started = Date()
        let sql = """
            SELECT s.Z_PK, s.ZNAME, s.ZRAWARTIST, a.ZNAME, s.ZDATEADDED, COUNT(h.Z_PK) AS plays
            FROM ZSNRSONG s
            JOIN ZSONGPLAYHISTORY h ON h.ZSONG = s.Z_PK
            LEFT JOIN ZSNRALBUM a ON a.Z_PK = s.ZALBUM
            GROUP BY s.Z_PK
            ORDER BY plays DESC, s.ZDATEADDED DESC
            LIMIT ?
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            let msg = String(cString: sqlite3_errmsg(db))
            Log.error("mostPlayedSongs prepare failed: \(msg)", category: LogCategory.doppler)
            throw DopplerLibraryError.query(msg)
        }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_int64(s, 1, Int64(limit))

        var rows: [SongRow] = []
        while sqlite3_step(s) == SQLITE_ROW {
            rows.append(SongRow(
                id: sqlite3_column_int64(s, 0),
                title: stringColumn(s, 1) ?? "(untitled)",
                artist: stringColumn(s, 2),
                album: stringColumn(s, 3),
                dateAdded: coreDataDate(s, 4),
                playCount: Int(sqlite3_column_int64(s, 5))
            ))
        }
        Log.info("mostPlayedSongs(limit: \(limit)) -> \(rows.count) rows in \(elapsedMs(started))ms", category: LogCategory.doppler)
        return rows
    }

    /// Resolves on-disk file locations for a set of song IDs. Used by the .m3u
    /// export. Each `ZSNRSONG.ZBOOKMARK` blob is a Doppler-specific "EBMK"
    /// envelope (4-byte magic + uint16-LE length + watched-folder root path)
    /// wrapped around a standard Foundation bookmark pointing at the audio
    /// file. We parse the envelope to recover the library root, then resolve
    /// the inner Foundation bookmark for the absolute file URL — `SongLocation`
    /// computes the relative path the m3u format wants. Songs without a
    /// bookmark or with an unresolvable one are returned with nil paths so the
    /// caller can decide whether to skip or warn.
    func songLocations(forIDs ids: [Int64]) throws -> [Int64: SongLocation] {
        guard !ids.isEmpty else { return [:] }
        let db = try requireOpen()
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
        let sql = "SELECT Z_PK, ZBOOKMARK FROM ZSNRSONG WHERE Z_PK IN (\(placeholders))"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw DopplerLibraryError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(s) }
        for (i, pk) in ids.enumerated() {
            sqlite3_bind_int64(s, Int32(i + 1), pk)
        }

        var result: [Int64: SongLocation] = [:]
        var resolved = 0
        while sqlite3_step(s) == SQLITE_ROW {
            let id = sqlite3_column_int64(s, 0)
            if let bytes = sqlite3_column_blob(s, 1) {
                let len = Int(sqlite3_column_bytes(s, 1))
                if len > 0 {
                    let data = Data(bytes: bytes, count: len)
                    let parsed = Self.parseDopplerBookmark(data)
                    result[id] = SongLocation(id: id, libraryRoot: parsed.root, absolutePath: parsed.path)
                    if parsed.path != nil { resolved += 1 }
                    continue
                }
            }
            result[id] = SongLocation(id: id, libraryRoot: nil, absolutePath: nil)
        }
        Log.info("songLocations(\(ids.count) ids) -> \(resolved) resolved", category: LogCategory.doppler)
        return result
    }

    /// Splits Doppler's EBMK-prefixed bookmark blob into the watched-folder
    /// root path (carried in the envelope) and the absolute file path
    /// (resolved out of the inner Foundation bookmark). The envelope layout:
    ///
    ///   bytes  0..3  : ASCII "EBMK" magic
    ///   bytes  4..5  : big-endian uint16 = length of root path string
    ///   bytes  6..6+N: UTF-8 root path (e.g. "/Users/you/Music")
    ///   bytes  6+N.. : standard Foundation bookmark blob ("book"-prefixed)
    ///
    /// Returns `(nil, nil)` for any blob that doesn't start with the EBMK
    /// magic so older or future Doppler formats fail closed instead of
    /// returning garbage.
    private static func parseDopplerBookmark(_ data: Data) -> (root: String?, path: String?) {
        guard data.count >= 6, data.prefix(4) == Data("EBMK".utf8) else { return (nil, nil) }
        let rootLen = (Int(data[4]) << 8) | Int(data[5])
        guard data.count >= 6 + rootLen else { return (nil, nil) }
        let rootData = data.subdata(in: 6..<(6 + rootLen))
        let root = String(data: rootData, encoding: .utf8)
        let inner = data.subdata(in: (6 + rootLen)..<data.count)

        var stale = false
        if let url = try? URL(
            resolvingBookmarkData: inner,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) {
            return (root, url.path)
        }
        // Foundation refused (likely sandbox + no security scope handed to us).
        // Fall back to scanning the inner blob for the absolute path string —
        // bookmarks store it in plaintext as `NSURLCanonicalPathKey`'s value.
        if let root, let scanned = scanForAbsolutePath(in: inner, prefix: root) {
            return (root, scanned)
        }
        return (root, nil)
    }

    /// Linear scan for an embedded absolute path inside a Foundation bookmark
    /// blob when full resolution isn't available. Looks for the library-root
    /// prefix as a UTF-8 substring, then keeps reading until a NUL/control
    /// byte. Tolerates non-ASCII bytes (UTF-8 continuation), so artist or
    /// album names with accents survive.
    private static func scanForAbsolutePath(in data: Data, prefix: String) -> String? {
        let needle = Array(prefix.utf8)
        guard !needle.isEmpty else { return nil }
        let bytes = [UInt8](data)
        guard bytes.count >= needle.count else { return nil }
        let lastStart = bytes.count - needle.count
        var i = 0
        while i <= lastStart {
            if bytes[i] == needle[0] {
                var match = true
                for j in 1..<needle.count where bytes[i + j] != needle[j] {
                    match = false; break
                }
                if match {
                    var end = i + needle.count
                    while end < bytes.count {
                        let b = bytes[end]
                        if b == 0x00 || (b < 0x20 && b != 0x09 && b != 0x0a && b != 0x0d) { break }
                        end += 1
                    }
                    if end > i + needle.count,
                       let s = String(data: data.subdata(in: i..<end), encoding: .utf8) {
                        return s
                    }
                }
            }
            i += 1
        }
        return nil
    }

    /// Tiny stopwatch for log lines — keeps query-timing one-liners readable.
    private func elapsedMs(_ start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    /// Core Data stores TIMESTAMP columns as seconds since 2001-01-01 (NSDate reference date).
    private func coreDataDate(_ stmt: OpaquePointer, _ idx: Int32) -> Date? {
        guard sqlite3_column_type(stmt, idx) != SQLITE_NULL else { return nil }
        let secs = sqlite3_column_double(stmt, idx)
        return Date(timeIntervalSinceReferenceDate: secs)
    }

    /// Asserts the DB is open and returns the raw pointer. Lets callers write
    /// `let db = try requireOpen()` instead of unwrapping `handle` everywhere.
    private func requireOpen() throws -> OpaquePointer {
        guard let db = handle else {
            throw DopplerLibraryError.query("database not open")
        }
        return db
    }

    /// `nil`-safe wrapper around `sqlite3_column_text` → Swift `String?`. SQLite
    /// returns `NULL` text pointers for SQL `NULL`, which would crash a naive
    /// `String(cString:)` call.
    private func stringColumn(_ stmt: OpaquePointer, _ idx: Int32) -> String? {
        guard let cstr = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: cstr)
    }

    // SQLITE_TRANSIENT tells SQLite to copy the bound bytes immediately, so we don't
    // have to keep the Swift String alive past the bind call.
    private static let transientDestructor = unsafeBitCast(
        OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self
    )
}
