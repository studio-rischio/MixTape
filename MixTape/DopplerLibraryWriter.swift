import AppKit
import Foundation
import SQLite3

/// The dangerous half of the Doppler library access: opens read-write and inserts
/// new playlists. Deliberately separated from the read-only `DopplerLibrary` so the
/// surface that can mutate Doppler's data is explicit.
///
/// Mirrors the Python prototype's logic in `agent_space/doppler_playlists.py` —
/// allocates `Z_PK` from `Z_PRIMARYKEY`, inserts into `ZPERSISTENTPLAYLIST` and
/// `Z_7SONGS` with the FOK ordering convention, all wrapped in one transaction.
actor DopplerLibraryWriter {
    private let bundleURL: URL
    private var handle: OpaquePointer?
    private var holdingScope = false

    /// Bundle identifier of the Doppler macOS app — verified via Spotlight.
    static let dopplerBundleID = "co.brushedtype.doppler-macos"

    private static let entityPlaylist: Int64 = 7
    /// FOK = "fractional ordering key". Spacing of 1024 leaves room to insert
    /// between items later without renumbering existing rows.
    private static let fokStep: Int64 = 1024

    enum WriteError: LocalizedError {
        case dopplerRunning
        case bookmarkAccessDenied
        case cannotOpen(String)
        case query(String)
        case noSongs

        var errorDescription: String? {
            switch self {
            case .dopplerRunning:
                return "Doppler is running. Quit Doppler first, then try again."
            case .bookmarkAccessDenied:
                return "Lost permission to access the Doppler library — re-pick it in Settings."
            case .cannotOpen(let m):
                return "Couldn't open Doppler library for writing: \(m)"
            case .query(let m):
                return "Database write failed: \(m)"
            case .noSongs:
                return "Playlist needs at least one song the user actually owns."
            }
        }
    }

    init(bundleURL: URL) {
        self.bundleURL = bundleURL
    }

    deinit {
        if let h = handle { sqlite3_close(h) }
        if holdingScope { bundleURL.stopAccessingSecurityScopedResource() }
    }

    /// Whether Doppler is currently running. Cheap to call repeatedly.
    nonisolated static func isDopplerRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: dopplerBundleID).isEmpty
    }

    func open() throws {
        guard handle == nil else { return }
        if Self.isDopplerRunning() {
            Log.warning("refused to open Doppler DB read-write because Doppler is running", category: LogCategory.doppler)
            throw WriteError.dopplerRunning
        }
        guard bundleURL.startAccessingSecurityScopedResource() else {
            throw WriteError.bookmarkAccessDenied
        }
        holdingScope = true

        let dbPath = DopplerLibraryLocation.dbFile(in: bundleURL).path
        Log.info("opening doppler DB read-write at \(dbPath)", category: LogCategory.doppler)
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(dbPath, &db, flags, nil)
        guard rc == SQLITE_OK, let opened = db else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "rc=\(rc)"
            if let opened = db { sqlite3_close(opened) }
            bundleURL.stopAccessingSecurityScopedResource()
            holdingScope = false
            throw WriteError.cannotOpen(msg)
        }
        handle = opened
    }

    func close() {
        if let h = handle {
            sqlite3_close(h)
            handle = nil
        }
        if holdingScope {
            bundleURL.stopAccessingSecurityScopedResource()
            holdingScope = false
        }
    }

    /// Creates a new playlist with the given name and song PKs. Returns the new
    /// `ZPERSISTENTPLAYLIST.Z_PK`. Wraps all inserts in a single transaction; rolls
    /// back on any error so the DB never sees a half-written playlist.
    func createPlaylist(name: String, songIDs: [Int64]) throws -> Int64 {
        guard !songIDs.isEmpty else { throw WriteError.noSongs }
        guard handle != nil else { throw WriteError.query("not open") }

        // Re-check right before the write — enough time may have passed since open()
        // for the user to relaunch Doppler.
        if Self.isDopplerRunning() {
            Log.warning("aborting write because Doppler is now running", category: LogCategory.doppler)
            throw WriteError.dopplerRunning
        }

        try exec("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let newPK = try allocateNewPlaylistPK()
            Log.debug("allocated playlist Z_PK=\(newPK)", category: LogCategory.doppler)

            let persistentID = UUID().uuidString.uppercased()
            try insertPlaylist(pk: newPK, name: name, persistentID: persistentID)

            for (i, songID) in songIDs.enumerated() {
                // Match the Python prototype: start at i+2 so the first track's FOK
                // leaves room to insert before it later.
                let fok = Int64(i + 2) * Self.fokStep
                try insertSongInPlaylist(playlistPK: newPK, songPK: songID, fok: fok)
            }

            try exec("COMMIT;")
            Log.info("wrote playlist \"\(name)\" Z_PK=\(newPK) with \(songIDs.count) songs", category: LogCategory.doppler)
            return newPK
        } catch {
            try? exec("ROLLBACK;")
            Log.error("createPlaylist rolled back: \(error.localizedDescription)", category: LogCategory.doppler)
            throw error
        }
    }

    // MARK: - Private write helpers

    /// Atomically allocates and reserves the next playlist primary key.
    ///
    /// Core Data uses `Z_PRIMARYKEY` as a per-entity allocator: each row holds the
    /// max PK value currently in use for that entity. To create a new row we read
    /// `Z_MAX`, add 1, and write the new max back — *both within the same
    /// transaction* as the actual INSERT, so two concurrent allocations can't
    /// collide. Failing to update `Z_MAX` would let Core Data hand out the same PK
    /// to its own subsequent inserts and corrupt the store.
    private func allocateNewPlaylistPK() throws -> Int64 {
        guard let db = handle else { throw WriteError.query("not open") }

        var sel: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT Z_MAX FROM Z_PRIMARYKEY WHERE Z_ENT = ?", -1, &sel, nil) == SQLITE_OK,
              let s = sel
        else {
            throw WriteError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_int64(s, 1, Self.entityPlaylist)
        guard sqlite3_step(s) == SQLITE_ROW else {
            throw WriteError.query("Z_PRIMARYKEY missing row for ENT=\(Self.entityPlaylist)")
        }
        let newPK = sqlite3_column_int64(s, 0) + 1

        var upd: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE Z_PRIMARYKEY SET Z_MAX = ? WHERE Z_ENT = ?", -1, &upd, nil) == SQLITE_OK,
              let u = upd
        else {
            throw WriteError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(u) }
        sqlite3_bind_int64(u, 1, newPK)
        sqlite3_bind_int64(u, 2, Self.entityPlaylist)
        guard sqlite3_step(u) == SQLITE_DONE else {
            throw WriteError.query("UPDATE Z_PRIMARYKEY failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        return newPK
    }

    /// Inserts the playlist row itself. The constants here match what Doppler
    /// writes for a freshly-created hand-made playlist:
    /// - `Z_ENT = 7` — Core Data entity ID (matches `entityPlaylist`).
    /// - `Z_OPT = 1` — Core Data's optimistic-locking version. New rows start at 1.
    /// - `ZISHIDDEN = 0`, `ZFOLDER = NULL` — top-level visible playlist.
    /// - `ZPERSISTENTID` — uppercase UUID; Doppler uses these to cross-reference
    ///   playlists across iCloud/devices. We mint a fresh one.
    /// - The three `NULL` source fields are only populated for streaming-service
    ///   playlists; user-created ones leave them empty.
    private func insertPlaylist(pk: Int64, name: String, persistentID: String) throws {
        guard let db = handle else { throw WriteError.query("not open") }
        let sql = """
            INSERT INTO ZPERSISTENTPLAYLIST
              (Z_PK, Z_ENT, Z_OPT, ZISHIDDEN, ZFOLDER, ZNAME, ZPERSISTENTID,
               ZSOURCEGROUPINGIDENTIFIER, ZSOURCEIDENTIFIER)
            VALUES (?, ?, 1, 0, NULL, ?, ?, NULL, NULL)
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw WriteError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_int64(s, 1, pk)
        sqlite3_bind_int64(s, 2, Self.entityPlaylist)
        sqlite3_bind_text(s, 3, name, -1, Self.transient)
        sqlite3_bind_text(s, 4, persistentID, -1, Self.transient)
        guard sqlite3_step(s) == SQLITE_DONE else {
            throw WriteError.query("INSERT ZPERSISTENTPLAYLIST failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    /// Inserts one row into the `Z_7SONGS` join table linking a playlist to a song.
    /// `Z_FOK_11SONGS` is Core Data's "fractional ordering key" — a sparse integer
    /// that defines display order. Spacing tracks by `FOK_STEP` (1024) leaves room
    /// for future inserts between existing tracks without renumbering everything.
    ///
    /// `UNIQUE(Z_7PLAYLISTS, Z_11SONGS)` constraint on this table — callers must
    /// dedupe before invoking. See `ShowcaseGenerator.addToDoppler` for the dedup.
    private func insertSongInPlaylist(playlistPK: Int64, songPK: Int64, fok: Int64) throws {
        guard let db = handle else { throw WriteError.query("not open") }
        let sql = """
            INSERT INTO Z_7SONGS (Z_7PLAYLISTS, Z_11SONGS, Z_FOK_11SONGS)
            VALUES (?, ?, ?)
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let s = stmt else {
            throw WriteError.query(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_int64(s, 1, playlistPK)
        sqlite3_bind_int64(s, 2, songPK)
        sqlite3_bind_int64(s, 3, fok)
        guard sqlite3_step(s) == SQLITE_DONE else {
            throw WriteError.query("INSERT Z_7SONGS failed: \(String(cString: sqlite3_errmsg(db)))")
        }
    }

    /// Convenience wrapper around `sqlite3_exec` for statements that don't bind
    /// parameters or read result rows (mainly `BEGIN`, `COMMIT`, `ROLLBACK`).
    /// Pulls the error message out of `sqlite3_exec`'s out-pointer (which we
    /// must `sqlite3_free`) and rethrows as `WriteError.query`.
    private func exec(_ sql: String) throws {
        guard let db = handle else { throw WriteError.query("not open") }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "exec rc=\(rc)"
            sqlite3_free(err)
            throw WriteError.query(msg)
        }
    }

    /// SQLite's `SQLITE_TRANSIENT` magic value (`(sqlite3_destructor_type)-1`),
    /// passed as the destructor argument to `sqlite3_bind_text` to tell SQLite
    /// to copy the bound bytes immediately. Without this, SQLite would hold a
    /// pointer into our temporary Swift `String` storage, which is unsafe.
    /// The `unsafeBitCast` is the standard workaround — Swift can't represent
    /// the C macro directly.
    private static let transient = unsafeBitCast(
        OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self
    )
}
