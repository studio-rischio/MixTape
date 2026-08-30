import AppKit
import Foundation

/// Stateless helpers for picking and persisting the user's Doppler library.
///
/// Sandboxed apps can't reach `~/Library/Application Support/Doppler/...` directly —
/// macOS requires the user to grant access via `NSOpenPanel`, then we persist that
/// permission as a **security-scoped bookmark** in `UserDefaults`. The bookmark
/// must be re-resolved on every launch and bracketed with
/// `startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()`
/// before any read or write to the underlying file.
///
/// Bookmark keying is versioned (`v1`) so we can invalidate stored bookmarks if we
/// ever need to change the format or the granted scope.
enum DopplerLibraryLocation {
    private static let bookmarkKey = "DopplerLibraryBookmark.v1"

    /// Resolves the persisted bookmark to a `URL?`. Returns `nil` if no bookmark
    /// is saved or if resolution fails (revoked permission, library moved, etc.) —
    /// in the failure case we also clear the stale bookmark so we don't keep
    /// retrying it on every launch.
    ///
    /// If the bookmark is "stale" (the OS asks us to refresh it), we briefly
    /// activate the scope and re-encode it back into UserDefaults. This usually
    /// happens after a macOS update or when the file has moved.
    static func resolveSavedURL() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else {
            Log.debug("no saved library bookmark", category: LogCategory.library)
            return nil
        }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            Log.warning("failed to resolve saved bookmark — clearing", category: LogCategory.library)
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
            return nil
        }
        Log.info("resolved saved library at \(url.path)", category: LogCategory.library)
        if stale, url.startAccessingSecurityScopedResource() {
            defer { url.stopAccessingSecurityScopedResource() }
            if let refreshed = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                UserDefaults.standard.set(refreshed, forKey: bookmarkKey)
                Log.info("refreshed stale bookmark", category: LogCategory.library)
            } else {
                Log.warning("bookmark was stale but couldn't refresh", category: LogCategory.library)
            }
        }
        return url
    }

    /// Encodes a security-scoped bookmark for `url` and persists it. Throws if
    /// the bookmark can't be created (typically because the URL wasn't granted
    /// access in this process — i.e., it didn't come out of `runOpenPanel`).
    static func save(_ url: URL) throws {
        let data = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(data, forKey: bookmarkKey)
        Log.info("saved library bookmark for \(url.lastPathComponent)", category: LogCategory.library)
    }

    /// Drops the persisted bookmark. The user will be prompted to re-pick on next
    /// launch. Used by Settings → "Forget Library".
    static func clear() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        Log.info("cleared saved library bookmark", category: LogCategory.library)
    }

    /// The Core Data SQLite file lives inside the `.dopplerdb` bundle (which is
    /// itself a directory). Both `DopplerLibrary` (read) and `DopplerLibraryWriter`
    /// (write) point `sqlite3_open_v2` at this path. `nonisolated` so it's callable
    /// from inside the actor without an `await` — the bundle URL is immutable.
    nonisolated static func dbFile(in libraryBundle: URL) -> URL {
        libraryBundle.appendingPathComponent("Contents/library")
    }

    /// The user's *real* home directory, even from a sandboxed app —
    /// `NSHomeDirectory()` returns the per-app container path under sandbox, which
    /// is useless for an open panel meant to find Doppler's user-domain files.
    /// `NSHomeDirectoryForUser(NSUserName())` is the documented escape hatch.
    private static var realHome: URL {
        URL(fileURLWithPath: NSHomeDirectoryForUser(NSUserName()) ?? NSHomeDirectory())
    }

    /// Best place to open the panel — falls back to a parent if the standard Doppler
    /// folder isn't there (e.g., Doppler not yet installed, or stored elsewhere).
    static var defaultPickerLocation: URL {
        let candidates = [
            "Library/Application Support/Doppler",
            "Library/Application Support",
            "Library",
        ]
        let fm = FileManager.default
        for path in candidates {
            let url = realHome.appendingPathComponent(path)
            if fm.fileExists(atPath: url.path) { return url }
        }
        return realHome
    }

    /// Errors thrown by `validate(_:)` when the user picks something that isn't a
    /// usable Doppler library bundle.
    enum PickError: LocalizedError {
        case notADopplerLibrary(URL)
        case missingDatabase(URL)

        var errorDescription: String? {
            switch self {
            case .notADopplerLibrary(let url):
                return "“\(url.lastPathComponent)” isn't a Library.dopplerdb bundle."
            case .missingDatabase(let url):
                return "Couldn't find Contents/library inside “\(url.lastPathComponent)”."
            }
        }
    }

    /// Shows a modal `NSOpenPanel` for picking the `.dopplerdb` bundle. Allows
    /// both files and directories because depending on Launch Services'
    /// understanding of the `.dopplerdb` UTType the bundle may appear as either.
    /// `showsHiddenFiles = true` so users can see `~/Library` (Finder hides it
    /// by default). Returns `nil` if the user cancels. `@MainActor` because
    /// `runModal()` must run on main.
    @MainActor
    static func runOpenPanel() -> URL? {
        Log.debug("showing library open panel at \(defaultPickerLocation.path)", category: LogCategory.ui)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Choose your Library.dopplerdb (typically in ~/Library/Application Support/Doppler)."
        panel.prompt = "Choose"
        panel.directoryURL = defaultPickerLocation
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else {
            Log.info("user cancelled library picker", category: LogCategory.ui)
            return nil
        }
        Log.info("user picked \(url.path)", category: LogCategory.ui)
        return url
    }

    /// Sanity-checks a freshly-picked URL: must end in `.dopplerdb` AND contain a
    /// readable `Contents/library` SQLite file. Briefly activates the security
    /// scope to do the existence check. Throws `PickError` on either failure so
    /// the caller (Settings UI) can show a clear message and let the user re-pick.
    static func validate(_ url: URL) throws {
        guard url.pathExtension.lowercased() == "dopplerdb" else {
            Log.warning("validation failed: not a .dopplerdb bundle (\(url.lastPathComponent))", category: LogCategory.library)
            throw PickError.notADopplerLibrary(url)
        }
        guard url.startAccessingSecurityScopedResource() else {
            Log.error("validation failed: could not start security scope", category: LogCategory.library)
            throw PickError.missingDatabase(url)
        }
        defer { url.stopAccessingSecurityScopedResource() }
        let dbFile = dbFile(in: url)
        guard FileManager.default.fileExists(atPath: dbFile.path) else {
            Log.error("validation failed: missing Contents/library inside \(url.lastPathComponent)", category: LogCategory.library)
            throw PickError.missingDatabase(url)
        }
        Log.debug("validated library bundle \(url.lastPathComponent)", category: LogCategory.library)
    }
}
