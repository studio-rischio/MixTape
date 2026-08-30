import AppKit
import Foundation

/// Stateless helpers for picking, persisting and writing into the user's chosen
/// .m3u save folder — the destination behind the detail sheet's **Save** button.
///
/// Why this exists at all: the app is sandboxed, and the only writable places it
/// gets for free are its own container (buried under
/// `~/Library/Containers/...`, useless for playlists you actually want to open)
/// and whatever an `NSSavePanel` hands back one file at a time. Skipping the
/// panel means holding a **security-scoped bookmark to a folder**, granted once
/// by the user, exactly like `DopplerLibraryLocation` does for the library
/// bundle. Every write has to be bracketed with
/// `startAccessingSecurityScopedResource()` or it fails with EPERM.
///
/// Deliberately a separate key/enum from `DopplerLibraryLocation` rather than a
/// generalisation of it: the two scopes are granted independently, and letting a
/// library bookmark satisfy a *write* to the music folder would quietly widen the
/// app's write surface.
enum PlaylistExportLocation {
    private static let bookmarkKey = "PlaylistExportFolderBookmark.v1"

    /// Resolves the persisted folder bookmark. Same stale-refresh dance as
    /// `DopplerLibraryLocation.resolveSavedURL` — a bookmark that can't be
    /// resolved is cleared rather than retried on every launch.
    static func resolveSavedURL() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            Log.warning("failed to resolve export folder bookmark — clearing", category: LogCategory.playlist)
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
            return nil
        }
        if stale, url.startAccessingSecurityScopedResource() {
            defer { url.stopAccessingSecurityScopedResource() }
            if let refreshed = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) {
                UserDefaults.standard.set(refreshed, forKey: bookmarkKey)
                Log.info("refreshed stale export folder bookmark", category: LogCategory.playlist)
            }
        }
        return url
    }

    /// Encodes and persists a security-scoped bookmark for `url`. Throws if the
    /// URL wasn't granted access in this process (i.e. it didn't come from
    /// `runFolderPanel`).
    static func save(_ url: URL) throws {
        let data = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(data, forKey: bookmarkKey)
        Log.info("saved export folder bookmark for \(url.lastPathComponent)", category: LogCategory.playlist)
    }

    /// Drops the persisted folder. The next Save re-prompts.
    static func clear() {
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        Log.info("cleared export folder bookmark", category: LogCategory.playlist)
    }

    /// Directory-only `NSOpenPanel`. `defaultDirectory` should be Doppler's
    /// watched-folder root when we know it — .m3u paths are written relative to
    /// that root, so saving there is what makes them resolve.
    @MainActor
    static func runFolderPanel(defaultDirectory: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to save playlists into. Saving inside your music folder keeps the .m3u paths working."
        panel.prompt = "Choose"
        if let defaultDirectory { panel.directoryURL = defaultDirectory }
        guard panel.runModal() == .OK, let url = panel.url else {
            Log.info("user cancelled export folder picker", category: LogCategory.ui)
            return nil
        }
        Log.info("user picked export folder \(url.path)", category: LogCategory.ui)
        return url
    }

    /// Failure modes specific to the no-panel save path.
    enum WriteError: LocalizedError {
        case folderUnavailable(URL)
        case accessDenied(URL)

        var errorDescription: String? {
            switch self {
            case .folderUnavailable(let url):
                return "The save folder “\(url.lastPathComponent)” no longer exists."
            case .accessDenied(let url):
                return "Couldn't get permission to write to “\(url.lastPathComponent)”. Pick the folder again in Settings."
            }
        }
    }

    /// Writes `text` into `folder` and returns the URL actually written.
    ///
    /// Never overwrites: if `fileName` is taken, appends " 2", " 3", … A playlist
    /// name is LLM-invented and a Regenerate can easily produce the same theme
    /// twice, so silently replacing a file the user already saved is the one
    /// outcome worth engineering against. Gives up after 99 and overwrites, which
    /// only happens if someone is deliberately hammering the same name.
    static func write(_ text: String, fileName: String, into folder: URL) throws -> URL {
        var isDirectory: ObjCBool = false
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }

        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw WriteError.folderUnavailable(folder)
        }

        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var target = folder.appendingPathComponent(fileName)
        var suffix = 2
        while FileManager.default.fileExists(atPath: target.path), suffix < 100 {
            target = folder.appendingPathComponent("\(base) \(suffix).\(ext)")
            suffix += 1
        }

        do {
            try text.write(to: target, atomically: true, encoding: .utf8)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && (error.code == NSFileWriteNoPermissionError || error.code == NSFileWriteVolumeReadOnlyError) {
            throw WriteError.accessDenied(folder)
        }
        return target
    }
}
