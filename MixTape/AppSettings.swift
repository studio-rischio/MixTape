import Foundation
import Observation

/// App-wide config singleton. Persists to UserDefaults via `didSet`; SwiftUI views
/// react to changes via `@Observable` (read `settings.foo` to subscribe; bind with
/// `$settings.foo` after wrapping with `@Bindable`).
///
/// Holds:
/// - LM Studio base URL + selected model ID (the LLM provider config).
/// - The user's chosen Doppler library URL (resolved from a security-scoped bookmark).
/// - `libraryRevision` — a counter we bump after writing to Doppler so view layers
///   that observe the library can refetch (see `MyDopplerView.onChange`).
/// - `showcaseThemeCount` — how many playlists each generation run should produce.
///
/// Singleton because nearly every view needs to read or react to it; making it
/// injected adds ceremony with no benefit for an app this size.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    /// Base URL of the local LM Studio server (e.g., `http://localhost:1234`).
    /// `didSet` writes through to UserDefaults so changes survive launches.
    var lmStudioBaseURL: String {
        didSet {
            UserDefaults.standard.set(lmStudioBaseURL, forKey: Self.lmBaseURLKey)
            Log.debug("lmStudioBaseURL set to \(lmStudioBaseURL)", category: LogCategory.llm)
        }
    }

    /// Currently selected LM Studio model ID (e.g., `qwen/qwen3.6-35b-a3b`).
    /// Empty string means "no model picked" — used by `isLLMConfigured`.
    var lmStudioModelID: String {
        didSet {
            UserDefaults.standard.set(lmStudioModelID, forKey: Self.lmModelKey)
            Log.info("lmStudioModelID set to \(lmStudioModelID.isEmpty ? "(none)" : lmStudioModelID)", category: LogCategory.llm)
        }
    }

    /// URL to the user's chosen `Library.dopplerdb` bundle. `nil` until the user
    /// picks one. The URL itself is held in memory; the persistent representation
    /// is a security-scoped bookmark managed by `DopplerLibraryLocation`.
    var libraryURL: URL?

    /// Folder that the detail sheet's **Save** button writes .m3u files into,
    /// resolved from a security-scoped bookmark managed by
    /// `PlaylistExportLocation`. `nil` until the user grants one — the first Save
    /// prompts for it, and every Save after that is a single click.
    ///
    /// Separate grant from `libraryURL`: the sandbox scopes the library bookmark
    /// to the `.dopplerdb` bundle, which says nothing about the music folder.
    var exportFolderURL: URL?

    /// Bumped after we mutate the Doppler DB (e.g., adding a generated playlist).
    /// Observers like `MyDopplerView` watch this with `.onChange` to refetch counts
    /// and playlist lists. The library URL itself doesn't change, so we need a
    /// separate signal — this is it.
    var libraryRevision: Int = 0

    /// How many themed playlists each Showcase generation run should produce.
    /// Clamped to 1...20 in the setter so the Stepper UI can't overshoot. Default 9.
    var showcaseThemeCount: Int {
        didSet {
            // Self-clamping: if the new value is out of range, recurse with the
            // clamped value and return early so the persist-to-UserDefaults branch
            // runs only once (with the in-range value).
            let clamped = min(20, max(1, showcaseThemeCount))
            if clamped != showcaseThemeCount {
                showcaseThemeCount = clamped
                return
            }
            UserDefaults.standard.set(showcaseThemeCount, forKey: Self.themeCountKey)
        }
    }

    /// How many tracks each generated playlist should aim for. Clamped to 10...150.
    /// Default 45.
    ///
    /// This is a *target*, not a guarantee — the prompt asks for "exactly N" (which
    /// lands far better than a range), but models undershoot, and unusable picks
    /// get dropped afterwards. Expect a bit under N.
    ///
    /// Raising it also widens the candidate pool via `perArtistLimit(forTarget:)`;
    /// asking for more tracks from the same shallow pool just forces the model to
    /// take nearly everything it was shown.
    var tracksPerPlaylist: Int {
        didSet {
            let clamped = min(150, max(10, tracksPerPlaylist))
            if clamped != tracksPerPlaylist {
                tracksPerPlaylist = clamped
                return
            }
            UserDefaults.standard.set(tracksPerPlaylist, forKey: Self.tracksPerPlaylistKey)
        }
    }

    /// How well-known the tracks in a generated playlist should be, using the
    /// global ListenBrainz listen counts cached in `mb_recording`.
    ///
    /// This filters the candidate list *before* the model sees it rather than
    /// asking the model to judge obscurity — it has no idea how popular anything
    /// is, and would guess. `.balanced` does no filtering, so it reproduces the
    /// behaviour from before this setting existed.
    enum Familiarity: String, CaseIterable, Sendable {
        case hits
        case balanced
        case deepCuts

        var label: String {
            switch self {
            case .hits: "Hits"
            case .balanced: "Balanced"
            case .deepCuts: "Deep cuts"
            }
        }

        var help: String {
            switch self {
            case .hits: "Favour the best-known tracks by each artist."
            case .balanced: "No preference — the model picks freely."
            case .deepCuts: "Favour lesser-known tracks and album cuts."
            }
        }
    }

    var familiarity: Familiarity {
        didSet {
            UserDefaults.standard.set(familiarity.rawValue, forKey: Self.familiarityKey)
            Log.info("familiarity set to \(familiarity.rawValue)", category: LogCategory.llm)
        }
    }

    /// How many pass-2 requests may be in flight at once. Clamped to 1...8,
    /// default 3.
    ///
    /// Pass 2 runs one request per theme and they used to all fire at once. LM
    /// Studio serves them concurrently against a single loaded model, and each
    /// reserves prompt + `max_tokens` worth of KV cache — so with the default of 9
    /// themes it reliably died with "Context size has been exceeded", failing most
    /// of the batch.
    ///
    /// The fix is a cap, not serialisation: measured against a local 4-request
    /// batch, running them in parallel finished 30s sooner than one at a time, so
    /// the concurrency is worth keeping. 3 leaves headroom on a modest context;
    /// raise it if the model has a large one, drop it to 1 if it still overflows.
    var maxConcurrentRequests: Int {
        didSet {
            let clamped = min(8, max(1, maxConcurrentRequests))
            if clamped != maxConcurrentRequests {
                maxConcurrentRequests = clamped
                return
            }
            UserDefaults.standard.set(maxConcurrentRequests, forKey: Self.maxConcurrentKey)
            Log.info("maxConcurrentRequests set to \(maxConcurrentRequests)", category: LogCategory.llm)
        }
    }

    /// How many songs per artist to ship in the pass-2 prompt, scaled to keep
    /// roughly a 3:1 ratio of candidates to picks (pass 1 selects 8–12 artists, so
    /// ~10 artists x this ≈ 3x the target). Never drops below the original 15,
    /// which is the value the prompt budget was tuned against.
    static func perArtistLimit(forTarget target: Int) -> Int {
        max(15, Int((Double(target) * 3.0 / 10.0).rounded(.up)))
    }

    /// Pass 2 asks the LLM to reply with indices into a numbered candidate list
    /// (`{"ids":[…]}`) instead of re-typing `{"title","artist"}` for every track.
    /// Roughly 18x cheaper on generated tokens, and a returned index maps straight
    /// to a `ZSNRSONG.Z_PK`, so tracks can't fail to resolve.
    ///
    /// Defaults on. The string-based path is still in `ShowcaseGenerator` behind
    /// this flag because ID-following is harder for small models than echoing text
    /// — turn it off to compare if a model starts returning junk.
    var useTrackIDSelection: Bool {
        didSet {
            UserDefaults.standard.set(useTrackIDSelection, forKey: Self.trackIDSelectionKey)
            Log.info("useTrackIDSelection set to \(useTrackIDSelection)", category: LogCategory.llm)
        }
    }

    private static let lmBaseURLKey = "lm_studio_base_url"
    private static let lmModelKey = "lm_studio_model_id"
    private static let themeCountKey = "showcase_theme_count"
    private static let trackIDSelectionKey = "showcase_use_track_id_selection"
    private static let tracksPerPlaylistKey = "showcase_tracks_per_playlist"
    private static let familiarityKey = "showcase_familiarity"
    private static let maxConcurrentKey = "showcase_max_concurrent_requests"

    /// Hydrates each setting from UserDefaults. The library URL is resolved via
    /// `DopplerLibraryLocation` which de-stales the bookmark if needed. Use
    /// `object(forKey:) as? Int` for `showcaseThemeCount` because `integer(forKey:)`
    /// can't distinguish "not set" from "0".
    private init() {
        lmStudioBaseURL = UserDefaults.standard.string(forKey: Self.lmBaseURLKey) ?? "http://localhost:1234"
        lmStudioModelID = UserDefaults.standard.string(forKey: Self.lmModelKey) ?? ""
        libraryURL = DopplerLibraryLocation.resolveSavedURL()
        exportFolderURL = PlaylistExportLocation.resolveSavedURL()
        showcaseThemeCount = (UserDefaults.standard.object(forKey: Self.themeCountKey) as? Int) ?? 9
        // `object(forKey:) as? Bool` for the same reason as themeCount: `bool(forKey:)`
        // returns false for "never set", which would silently default this off.
        useTrackIDSelection = (UserDefaults.standard.object(forKey: Self.trackIDSelectionKey) as? Bool) ?? true
        tracksPerPlaylist = (UserDefaults.standard.object(forKey: Self.tracksPerPlaylistKey) as? Int) ?? 45
        familiarity = (UserDefaults.standard.string(forKey: Self.familiarityKey)
            .flatMap(Familiarity.init(rawValue:))) ?? .balanced
        maxConcurrentRequests = (UserDefaults.standard.object(forKey: Self.maxConcurrentKey) as? Int) ?? 3
    }

    /// True iff a model is selected and the base URL parses with a host. Used by
    /// the first-run gate and by `ShowcaseView`'s locked state.
    var isLLMConfigured: Bool {
        guard !lmStudioModelID.isEmpty else { return false }
        guard let url = URL(string: lmStudioBaseURL), url.host != nil else { return false }
        return true
    }

    /// Convenience wrapper that returns `lmStudioBaseURL` as a `URL?`.
    var lmStudioURL: URL? {
        URL(string: lmStudioBaseURL)
    }

    /// Updates the active library: persists the security-scoped bookmark via
    /// `DopplerLibraryLocation.save` (or clears it on `nil`) and updates the
    /// Observable property so views re-render. Errors during bookmark save are
    /// logged but don't propagate — this is called from button handlers.
    func updateLibrary(_ url: URL?) {
        if let url {
            do {
                try DopplerLibraryLocation.save(url)
                libraryURL = url
            } catch {
                Log.error("save library failed: \(error.localizedDescription)", category: LogCategory.library)
            }
        } else {
            DopplerLibraryLocation.clear()
            libraryURL = nil
        }
    }

    /// Updates the .m3u save folder, persisting the security-scoped bookmark (or
    /// clearing it on `nil`). Mirrors `updateLibrary` — bookmark failures are
    /// logged rather than thrown, since every caller is a button handler.
    func updateExportFolder(_ url: URL?) {
        if let url {
            do {
                try PlaylistExportLocation.save(url)
                exportFolderURL = url
            } catch {
                Log.error("save export folder failed: \(error.localizedDescription)", category: LogCategory.playlist)
            }
        } else {
            PlaylistExportLocation.clear()
            exportFolderURL = nil
        }
    }
}
