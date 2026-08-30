# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A macOS SwiftUI app that uses a local LLM ([LM Studio](https://lmstudio.ai)) to generate themed playlists from the user's [Doppler](https://brushedtype.co/doppler/) library and writes them back into Doppler's Core Data SQLite store. [README.md](README.md) is the user-facing guide — read it for the intended UX before changing behavior.

User-visible shape:

- **My Doppler** tab — library stats, recently added, most played, existing playlists, sync banner.
- **Discover** tab — grid of LLM-generated playlists whose themes the model invented from the library. Each tile opens a detail sheet with the tracklist plus **Add to Doppler** (writeback), **Save .m3u** (one click into a remembered folder, with **Export .m3u…** and the folder controls in its menu), and a per-tile **Retry** when an individual playlist fails.
- **Create** tab — two modes behind a segmented picker. *Describe* takes a typed brief ("Italian dinner night") and runs the same two-pass pipeline. *More like this* takes a seed track and builds a playlist by collaborative filtering, **with no LLM call at all** — so it stays usable with LM Studio closed, and its LLM gate is rendered inline rather than replacing the screen (otherwise the mode picker itself becomes unreachable).
- **Settings (⌘,)** — LLM provider, library picker, .m3u save folder, cache management.
- **Debug Log (⌘⌥L)** — in-app log viewer.

The Discover tab is named `Showcase` throughout the code (`ShowcaseView`, `ShowcaseGenerator`, `ShowcaseEntry`, the `Tab.showcase` case). That's the original name, deliberately kept — don't rename it as a drive-by. The user-visible label has been "Playlists" and is now "Discover"; the code name has never moved.

**Discover and Create share one `entries` array** on `ShowcaseGenerator`, tagged by `ShowcaseEntry.source` (`.discover` / `.created`). That's deliberate: `addToDoppler`, `exportM3U` and `retryEntry` all look an entry up by UUID, so both tabs get them for free. The tabs filter via `discoverEntries` / `createdEntries`. Two consequences to preserve — `generate()` must only clear `.discover` entries (a Regenerate shouldn't destroy the user's Create results), and Create runs on its own `createPhase`/`createTask` so the two tabs don't fight over `phase`.

## Getting oriented

```sh
# Debug build — the fast inner loop. Add -quiet to cut the log noise.
xcodebuild -project MixTape.xcodeproj -scheme MixTape -configuration Debug -destination 'platform=macOS' build

# Release build into ./build (git-ignored), then launch the .app
./build.sh

open -a Xcode MixTape.xcodeproj   # or open in Xcode and ⌘R
```

No tests, lint config, or package manifests exist. No third-party dependencies — only `SQLite3` (system), SwiftUI, AppKit, Foundation, OSLog.

To actually exercise the app you need Doppler installed with a populated library, and LM Studio running with a model loaded at ≥ 8 K context. Without those, most of the interesting paths are unreachable.

Everything lives in [MixTape/](MixTape/) (`SDKROOT = macosx`, `MACOSX_DEPLOYMENT_TARGET = 15.7`, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, app-sandboxed). The Xcode target uses `PBXFileSystemSynchronizedRootGroup`, so files added to that directory are picked up automatically — **never edit [project.pbxproj](MixTape.xcodeproj/project.pbxproj) just to add sources.**

**The project deliberately has no `DEVELOPMENT_TEAM`.** `CODE_SIGN_STYLE` stays `Automatic`; with no team set, macOS signs the app ad-hoc and the sandbox entitlements still apply, so `xcodebuild` and `./build.sh` work for anyone with zero setup. If Xcode writes a team back into `project.pbxproj` after someone picks one in *Signing & Capabilities*, **don't commit it** — a committed team ID breaks every other contributor's build.

The app icon ships as an Icon Composer bundle at [MixTape.icon/](MixTape/MixTape.icon/), wired up via `ASSETCATALOG_COMPILER_APPICON_NAME = MixTape`. The source artwork is in [icon/](icon/).

The landing page is [docs/index.html](docs/index.html) — a single self-contained file with its assets in [docs/](docs/), served by GitHub Pages from `main` → `/docs` at <https://rischio.studio/MixTape/>. The `studio-rischio` account has a custom domain, so the `github.io` address only redirects there; link the `rischio.studio` form.

**Identity is set in [project.pbxproj](MixTape.xcodeproj/project.pbxproj) and must stay in sync in three places:** `PRODUCT_BUNDLE_IDENTIFIER` (`studio.rischio.mixtape`) also appears as the OSLog `subsystem` in [Log.swift](MixTape/Log.swift) and as the container path documented below. `INFOPLIST_KEY_NSHumanReadableCopyright` is the single source of truth for the copyright string macOS shows in the About panel.

## Architecture (load-bearing context)

### Two halves of Doppler access

- **[DopplerLibrary.swift](MixTape/DopplerLibrary.swift)** — read-only actor. Opens with `SQLITE_OPEN_READONLY`. Safe to call while Doppler is running. Also owns `songLocations(forIDs:)` + the EBMK bookmark parser used by the .m3u export (see "Doppler bookmark format" below) — still strictly read-only.
- **[DopplerLibraryWriter.swift](MixTape/DopplerLibraryWriter.swift)** — read-write actor, deliberately separate. Refuses to open if `NSRunningApplication.runningApplications(withBundleIdentifier: "co.brushedtype.doppler-macos")` returns anything. Re-checks again right before the actual write (long gap between LLM gen and user click).

Always preserve this split — making Doppler read-write through one type would erase the explicit danger surface.

### Sandbox + bookmark architecture

The app is sandboxed (entitlements: [MixTape.entitlements](MixTape/MixTape.entitlements)):

- `com.apple.security.files.user-selected.read-write` — granted via NSOpenPanel
- `com.apple.security.files.bookmarks.app-scope` — to persist the choice across launches
- `com.apple.security.network.client` — for LM Studio + MusicBrainz

[DopplerLibraryLocation.swift](MixTape/DopplerLibraryLocation.swift) handles the picker + security-scoped bookmark dance. The picker explicitly walks the user's *real* `~/Library/Application Support/Doppler` (via `NSHomeDirectoryForUser(NSUserName())` — `NSHomeDirectory()` returns the sandbox container) and enables `showsHiddenFiles` so they can navigate into `~/Library`.

### Artist names: the canonicalization contract

Doppler stores artists twice — `ZSNRARTIST.ZNAME` (the entity, what the sync enumerates) and the denormalized `ZSNRSONG.ZRAWARTIST` string (what songs actually carry). The MusicBrainz cache is keyed by a third thing again. All three are bridged by one rule, and **it is duplicated in two languages**:

- Swift: `MetadataCache.canonicalize(_:)` = `lowercased()` + `trimmingCharacters(in: .whitespacesAndNewlines)`.
- Swift, for keys that came from SQL: `MetadataCache.sqlCanonicalize(_:)`. **SQLite's `LOWER()` only maps ASCII A–Z** while Swift's `lowercased()` is Unicode-aware — `LOWER('BJÖRK')` is `bjÖrk`, `"BJÖRK".lowercased()` is `björk`. Any Swift string being matched against a SQL-produced key (the `mb_recording` primary key, `sampleSongsByArtist`'s grouping key, `SongIdentity.canonical*`) must use this one, or it silently misses.
- SQL: `LOWER(TRIM(s.ZRAWARTIST))` — the grouping key in `sampleSongsByArtist` and `albumsByArtist`, and the `mb_artist.canonical_name` primary key.

If you change one, change the other. A mismatch doesn't crash — it silently returns an empty `songsByArtist` lookup, so every theme throws "has no artists in the user's library" and the whole Playlists grid fails. Any new artist-keyed dictionary must use the same function.

### State gating chain

Three gates run in sequence; a change to any one of them can strand the user on an empty screen:

1. **LLM configured** — `ContentView.task` calls `openSettings()` on first run when `AppSettings.isLLMConfigured` is false (model ID non-empty *and* base URL parses with a host).
2. **Library picked** — not gated at the tab level; `MyDopplerView` has its own no-library empty state.
3. **Metadata sync completed** — `ShowcaseView` and `CreateView` both lock until `MetadataCache.hasCompletedInitialSync`. It's set once the **artist** stage finishes, not the whole sync — pass 1 only needs artist metadata, so there's no reason to make the user wait for track matching. Settings → Reset Cache clears it and relocks.

   It is a **stored** `@Observable` property, persisted to `UserDefaults` (`metadata_cache_initial_sync_complete`) via the private `setInitialSyncComplete(_:)`, which is the only writer. It used to be a computed property reading the default on each access, and that silently broke the gate: `@Observable` tracks stored properties only, so reading it in a view body registered no dependency and nothing re-rendered when it flipped. `ShowcaseView` unlocked anyway purely because its locked state also reads `phase` for the progress bar; `CreateView`'s locked state reads nothing observable, so it stayed stuck until relaunch. **Don't gate UI on a computed property that reads `UserDefaults`** — the same trap applies to any new one.

After a successful write, `ShowcaseGenerator.addToDoppler` bumps `AppSettings.libraryRevision`; `MyDopplerView.onChange(of:)` watches that counter to refetch. The library URL doesn't change on write, so this counter is the only refresh signal — new views that display library data should observe it too.

Generated playlists live **in memory only** (`ShowcaseGenerator.entries`) and are lost on quit unless added to Doppler or exported.

### Familiarity filter

`AppSettings.familiarity` (`.hits` / `.balanced` / `.deepCuts`, default `.balanced`) narrows each artist's candidate songs by the global listen counts cached in `mb_recording`, **before** the model sees them. Deliberately not asked of the LLM — it has no idea how popular anything is and would invent an answer.

Three things keep it honest:

- `.balanced` is a literal pass-through, so the pre-familiarity behaviour is preserved exactly.
- When a preference *is* set, `sampleSongsByArtist` is asked for `familiarityPoolMultiplier` (3×) as many songs, then `applyFamiliarity` trims back to `perArtistLimit`. Ranking a list that's already been truncated to what you'll use accomplishes nothing.
- Tracks with **no** cached count (~10% of a real library, and everything if the recording sync hasn't run) are scored as the artist's **median**, not zero. Treating unknown as obscure would fill "deep cuts" with tracks whose only distinction is a typo in their metadata.

### "More like this" (similarity walk)

`ShowcaseGenerator.createSimilar(seedTitle:seedArtist:libraryURL:)` — no LLM, no prompts. It takes the seed's *strings*, not its `Z_PK`: the picker returns whichever row matched, while `allSongIdentities` groups by canonical `(artist, title)` and keeps only `MIN(Z_PK)`, so for a song on two albums an ID lookup would fail on the copy that lost. Seed track → ListenBrainz `similar-recordings` → keep what the user owns → those become the next frontier, breadth-first.

**The walk exists because one seed isn't enough.** Measured on a 2,923-track library: a single seed's similar list overlaps the library by only ~4 tracks (7.6% of ~57 results). Two levels reliably fills 45. Capped at 4 levels — past that the results have drifted far enough that "more like this" stops being true.

`ListenBrainzClient.similarRecordings(to:)` is **GET with `recording_mbids` repeated once per seed**. The POST form 400s and a comma-separated list fails UUID validation — both verified. Repeating the parameter is what makes a whole frontier one request instead of one per track; `reference_mbid` on each row says which seed it came back for.

Coverage is uneven *by design*, not broken: well-listened artists return 50–100 similar recordings, obscure ones return nothing. `ShowcaseSimilarError.noSimilarData` says so in plain language. Failures drop the tile rather than marking it `.failed`, because the detail sheet's Retry re-runs pass 2 against an LLM and this path never used one.

### Local cache

The MusicBrainz metadata cache lives at `~/Library/Containers/studio.rischio.mixtape/Data/Library/Application Support/MixTape/metadata-cache.sqlite`. No entitlements needed — it's the app's own container. Owned by [MetadataCacheStore.swift](MixTape/MetadataCacheStore.swift); single table `mb_artist(canonical_name PK, name, mbid, disambiguation, type, country, tags-as-JSON, last_fetched_at)`.

A failed or unmatched lookup is still cached (with `mbid: nil`) so a bad artist name isn't retried on every launch.

### LLM pipeline (two-pass)

[ShowcaseGenerator.swift](MixTape/ShowcaseGenerator.swift) is a `@MainActor @Observable` orchestrator that runs:

1. **Pass 1 — themes**: small prompt (artists + tags + albums), single LM Studio call, returns `{themes: [{name, description, artists}]}`. Theme count is `AppSettings.showcaseThemeCount` (default 9, range 1–20, set via the Stepper next to Generate).
2. **Pass 2 — tracks per theme** (parallel via `withTaskGroup`, bounded — see "Request concurrency"): per theme, ships only that theme's artists with their actual song titles, asks for exactly `AppSettings.tracksPerPlaylist` tracks (default 45), returns `{ids: [...]}` in ID mode or `{tracks: [{title, artist}]}` in string mode. Each playlist's tile flips from "Picking tracks…" to its tracklist as its call returns.

The two-pass shape exists for two reasons that are easy to forget:

- LM Studio model context is often only 4 K — a one-shot of the whole library + N playlists × 45 tracks blows the budget.
- Per-theme prompts ship only the relevant artists' real song titles, so the LLM picks from your library instead of inventing — match rate jumped from ~19 % (one-shot, no song titles) to ~100 % (two-pass with titles).

**Track resolution** (end of pass 2, in `generateTracksForTheme`) has two modes, chosen by `AppSettings.useTrackIDSelection` (**default on**).

*ID mode (default).* `buildTrackIDsPrompt` numbers every candidate track in one flat sequence across all of the theme's artists and keeps an `[Int: IndexedCandidate]` map; the LLM replies `{"ids": [...]}` and each index maps straight to a `ZSNRSONG.Z_PK`. Nothing is matched by string, so a track cannot fail to resolve — roughly 18× cheaper on generated tokens than echoing titles, and it removes ~45 `findSong` calls per theme. The only failures are indices that are **out of range** or **repeated**; those are dropped, counted into `ShowcaseEntry.unusablePicks` ("N unusable picks" in the detail sheet), and logged individually with their reason. Dedupe keys on the **song ID, not the prompt index** — the same song can be numbered twice if the LLM repeats an artist within a theme, and `Z_7SONGS UNIQUE(playlist, song)` keys on the song.

*String mode (fallback, flag off).* The original path: each LLM-named `(title, artist)` is resolved by `DopplerLibrary.findSong` — strict `LOWER(TRIM(title)) AND LOWER(TRIM(artist))` first, then a **title-only fallback**, because the LLM formats artist strings differently from `ZRAWARTIST` ("X feat. Y" vs "X"). Unresolved tracks are kept with `dopplerSongID == nil` so the UI strikes them through. That "show it, don't write it" behavior only applies here; in ID mode there is no unresolved track to show, and `unusablePicks` is the equivalent signal.

Both modes silently drop unresolved tracks from the Doppler write and the .m3u export. Keep the string path around — ID-following is harder for small models than echoing text, and the flag is how you compare.

`sampleSongsByArtist` returns `[String: [SongCandidate]]` (id + title) rather than bare titles precisely so ID mode has the `Z_PK` in hand. `GeneratedTrack.id` prefers `dopplerSongID` over `"title|artist"` — the string form collides when one song sits on two albums, which gives `ForEach` duplicate identifiers.

**Prompt size budget.** The numbers in the prompt builders were tuned against 4 K-context models and are load-bearing, not arbitrary: pass 1 ships ≤3 MusicBrainz tags and ≤4 albums per artist. Temperature is 0.85 / 0.7 for the two passes. Raising these risks `n_keep > n_ctx` failures on small models.

### Request concurrency and token budgets

**Pass 2 is bounded, not unbounded.** `AppSettings.maxConcurrentRequests` (default 3, range 1–8) caps how many theme requests are in flight; the task group primes that many and starts the next only as a slot frees. Previously every theme fired at once, so the default of 9 themes meant 9 simultaneous requests. LM Studio serves them concurrently against one loaded model and each reserves prompt + `max_tokens` of KV cache, which has been observed to produce:

```
HTTP 400: {"code":500,"message":"Context size has been exceeded."}
```

killing most of a batch. Whether it happens depends on the model's configured context length, so it reproduces intermittently. Note the shape — a 400 whose body wraps an engine 500 — so the status code alone can't identify it; `LMStudioClient.Error.fromHTTP` sniffs the body and maps it to `.contextExceeded` with an actionable message instead of a bare "HTTP 400". **Don't go back to unbounded**: the cap is cheap (measured slightly *faster* than firing 9 at once, since contention slows every request) and it bounds peak context demand.

**`maxTokens` is sized for reasoning models, not for the answer.** Pass 1 is 8192 though its JSON answer is only ~150 tokens, because `reasoning_content` counts against the same budget. Measured with Qwen3 on a 149-artist library, reasoning alone ran 5,700–8,700 chars (~1,700–2,600 tokens): at the old 2048 the model routinely spent the whole budget thinking and returned `finish_reason=length` with **empty content** — two failures in three trials. Pass 2 stays at `max(3500, target × 25)`, since raising it multiplies against the concurrency cap and in ID mode the answer is only ~33 tokens.

**Track count is `AppSettings.tracksPerPlaylist`** (default 45, range 10–150, stepper in both Discover and Create). It's threaded to `generateTracksForTheme` as `trackTarget` — that function is `static` and runs off-actor in the task group, so it can't read `AppSettings` itself, same as `useTrackIDs`. Two things scale with it and must stay in step:

- **The candidate pool.** `AppSettings.perArtistLimit(forTarget:)` = `max(15, ceil(target * 3 / 10))`, keeping roughly 3 candidates per pick (pass 1 selects 8–12 artists). Raising the target without widening the pool just forces the model to take nearly everything it was shown, and quality collapses.
- **`maxTokens`** = `max(3500, target * 25)`. Only matters in string mode (~14 tokens/track); ID mode never gets close, since 45 IDs cost ~33 tokens.

The default of 45 keeps the original tuning exactly — `perArtistLimit` stays 15 and `maxTokens` stays 3500. **Targets above ~60 will exceed a 4 K context.** That's the documented trade: the setting exists, but the old guarantee only holds at the default.

"Exactly N" is still the phrasing, because it lands more reliably than a range. It's a target, not a guarantee — models undershoot and unusable picks get dropped, so finished playlists run slightly under N.

`retryEntry(entryID:)` re-runs **only pass 2** for one entry — reconstructs the original `ProposedTheme` from the stored entry metadata (name + description + plannedArtists), so a single failure doesn't force the whole batch to regenerate. Wired to the per-tile **Retry** button in the failed-state of `ShowcaseDetailSheet`.

### LLM client quirks

[LMStudioClient.swift](MixTape/LMStudioClient.swift) handles things that bit us:

- **Use `response_format = "json_schema"`, never `"json_object"`.** LM Studio rejects `"json_object"` with HTTP 400. Don't pass `strict: true` either — many backends choke on it.
- **Keep the schemas minimal.** `themesSchema` / `tracksSchema` in `ShowcaseGenerator` deliberately omit `additionalProperties: false`, `strict`, and `minItems`/`maxItems`. Adding them made LM Studio's constrained-decoding grammar emit empty output. Count constraints belong in the prompt text ("exactly N tracks"), not the schema.
- **Reasoning models put structured output in `reasoning_content`, not `content`.** Qwen 3 / DeepSeek-R1 etc. emit JSON via their thinking pass; `content` ends up empty. The client falls back to `reasoning_content` automatically and the log line tells you which field was used (`from content` vs `from reasoning_content`).
- Parsing goes through `decodeWithFallback`, which retries on the substring from the first `{` to the last `}` — reasoning models wrap their JSON in prose despite the schema.

### MusicBrainz quirks

[MusicBrainzClient.swift](MixTape/MusicBrainzClient.swift):

- Anonymous use is **1 req/sec rate-limited**; respect it with `Task.sleep(for: .seconds(1))` between calls.
- Required: descriptive `User-Agent` header with a contactable URL. We use `MixTape/1.0 (+https://github.com/studio-rischio/MixTape)` — if the repo ever moves, update it, or MusicBrainz may start rejecting requests.
- Score-only top-hit picking gives the wrong entity for ambiguous names (e.g., "Beck" the German voice actor outranks Beck the musician). The client compensates with a **musical-tag disambiguation pass**: walks the top 10 candidates and prefers the highest-scored one whose tags contain any of ~30 musical hint substrings. Only kicks in when the top hit lacks musical tags, so it's a no-op for unambiguous artists.

### Logging

[Log.swift](MixTape/Log.swift) — `Log.{debug,info,warning,error}(_:category:)` callable from any isolation context (everything `nonisolated`). Mirrors to OSLog and appends to a capped `LogStore.shared`. Categories: `ui`, `library`, `doppler`, `llm`, `playlist`, `process`. The Debug Log window ([DebugLogView.swift](MixTape/DebugLogView.swift), ⌘⌥L) renders the store with filters.

### Theming

[Theme.swift](MixTape/Theme.swift) is the single source of truth for the palette — derived from Doppler's icon (dark purple rgb 72/64/168, light purple rgb 108/90/204, lavender rgb 217/213/240) plus two container tones (`windowBackground` near-black with a faint purple cast, `panel` brighter so cards read as elevated). The accent color is wired through `Assets.xcassets/AccentColor.colorset` so SwiftUI controls inherit it for free.

The app is forced dark (`.preferredColorScheme(.dark)` on every Scene root). The window background is painted via `.containerBackground(Theme.windowBackground, for: .window)` on the root of the main window and the Settings scene. Don't reach for `Color(nsColor: .controlBackgroundColor)` for new card surfaces — use `Theme.panel` + `Theme.panelBorder` so elevation stays consistent. Playlist tiles are the deliberate exception: they use a deterministic FNV-1a hash of the theme name to pick a multi-color gradient, so each tile feels distinct.

### .m3u export + Doppler bookmark format

[ShowcaseGenerator.exportM3U(entryID:)](MixTape/ShowcaseGenerator.swift) builds an Extended M3U (`#EXTM3U` + `#PLAYLIST:<name>` + one path per line) for a single entry. Path format matches Doppler's on-disk layout: `Artist/Album/01 Title.ext`, **relative to the watched-folder root**, so the file plays back from any music app launched in that root.

`exportM3U` only *builds* the file — it never writes. Two callers do, both in `ShowcaseDetailSheet`, behind one split button:

- **Save .m3u** (primary action, `performSave`) writes straight into `AppSettings.exportFolderURL` with no panel.
- **Export .m3u…** (menu item, `performExport`) is the original `NSSavePanel` path, defaulted to the watched-folder root.

The save folder is a **second, independent security-scoped bookmark** owned by [PlaylistExportLocation.swift](MixTape/PlaylistExportLocation.swift) — the same dance as `DopplerLibraryLocation`, different UserDefaults key. Keep them separate: the library grant is scoped to the `.dopplerdb` bundle and says nothing about the music folder, so letting one satisfy the other would quietly widen the app's *write* surface. No new entitlement is involved; `user-selected.read-write` + `bookmarks.app-scope` already cover it. Every write must be bracketed with `startAccessingSecurityScopedResource()` or it fails with EPERM.

Three behaviours worth preserving:

- **First Save prompts, later ones don't.** `performSave` builds the export once and reuses it across the picker branch — asking the generator to save, catching "no folder", then asking again re-opens the library on every attempt.
- **A vanished folder re-prompts instead of erroring.** `PlaylistExportLocation.write` reports `.folderUnavailable`; `performSave` drops the stale grant and runs the picker rather than dead-ending on an alert.
- **Never overwrite.** A repeated name gets " 2", " 3", … Theme names are LLM-invented and a Regenerate can easily produce the same one twice, so silently replacing a file the user already saved is the outcome worth engineering against.

With no save panel appearing there's no inherent feedback, so the button flips to "Saved" and the footer grows a link that reveals the file in Finder.

The watched-folder root and the file's absolute URL both come out of `ZSNRSONG.ZBOOKMARK`, which Doppler stores in its own envelope format:

```
bytes  0..3  : ASCII "EBMK" magic
bytes  4..5  : big-endian uint16 = length N of root path string
bytes  6..6+N: UTF-8 watched-folder root (e.g. "/Users/you/Music")
bytes  6+N.. : standard Foundation bookmark blob ("book"-prefixed)
```

[DopplerLibrary.songLocations(forIDs:)](MixTape/DopplerLibrary.swift) parses the envelope, then resolves the inner Foundation bookmark with `URL(resolvingBookmarkData:)`. If sandbox blocks resolution, it falls back to a byte-scan that finds the absolute path string (stored in plaintext as the bookmark's `NSURLCanonicalPathKey` value) by searching for the watched-folder prefix. Either way, `SongLocation.relativePath` strips the prefix to produce the m3u-ready path.

If a future Doppler version drops or restructures EBMK, `parseDopplerBookmark` returns `(nil, nil)` and the export gracefully degrades to "no resolvable tracks" — fail closed, never write garbage paths.

## How Doppler's data store works (load-bearing context)

Doppler stores its library as a **Core Data SQLite** database inside a `.dopplerdb` bundle:

- Path: `~/Library/Application Support/Doppler/Library.dopplerdb/Contents/library`
- Bundle ID of the macOS app: `co.brushedtype.doppler-macos`

Key tables and columns the app relies on:

- `ZPERSISTENTPLAYLIST` — playlist rows. `Z_PK` is the primary key; `ZNAME` is the title; `Z_OPT` is Core Data's optimistic-locking version counter (**must be incremented on every update**).
- `ZSNRSONG` — songs. `ZNAME`, `ZRAWARTIST`, `ZALBUM` (FK), `ZDATEADDED` (Core Data timestamp = seconds since 2001-01-01), `ZLIKEDAT`, `ZISMISSING`. Songs whose file has vanished carry `ZISMISSING = 1`; every read query that feeds the UI or a prompt filters them out with `(ZISMISSING IS NULL OR ZISMISSING = 0)` — keep that predicate on any new query, or the LLM will pick tracks that can't play or export.
- `ZSNRARTIST` / `ZSNRALBUM` — artist/album entities. Artists have no `ZPERSISTENTID`; songs reference artists via the denormalized `ZRAWARTIST` string.
- `ZSONGPLAYHISTORY` — event log of plays (`ZSONG`, `ZDATE`, `ZDURATION`). Aggregate with `COUNT(*) GROUP BY ZSONG` for "most played".
- `Z_7SONGS` — playlist↔song join table. Columns: `Z_7PLAYLISTS` (playlist PK), `Z_11SONGS` (song PK), `Z_FOK_11SONGS` (sort key). **`UNIQUE(Z_7PLAYLISTS, Z_11SONGS)` constraint** — dedupe song IDs before insert or the whole transaction rolls back.
- `Z_PRIMARYKEY` — Core Data's PK allocator. Before inserting a new row, read `Z_MAX` for the entity and write back the incremented value, or Core Data will collide on next launch.

Hardcoded magic numbers in `DopplerLibraryWriter`:

- `ENT_PLAYLIST = 7` and `ENT_SONG = 11` are Core Data entity IDs. These match the `7` and `11` in `Z_7SONGS` / `Z_7PLAYLISTS` / `Z_11SONGS`. **If Doppler ships a schema migration these IDs may shift** — verify against `Z_PRIMARYKEY` and `sqlite_master` before trusting them.
- `fokStep = 1024` is the spacing between successive `Z_FOK_*` ordering keys (Core Data's "fractional ordering key" convention). The writer starts at `(i+2) * fokStep` so the first track has room before it.

Write-path safety rules (preserve in any new code):

1. **Refuse to write while Doppler is running** — Doppler holds the SQLite file and would overwrite changes on quit. Check both at `open()` and right before the write.
2. **Wrap the inserts in `BEGIN IMMEDIATE TRANSACTION` … `COMMIT`**, with `ROLLBACK` on any error. Atomicity is mandatory — a half-written playlist looks broken in Doppler.
3. **Dedupe song IDs** before inserting into `Z_7SONGS` (LLMs occasionally repeat tracks in long playlists).

## Inspecting a real library

The fastest way to check a schema assumption is to query a copy of the database directly. Always use `-readonly`, and never point a write at a live library:

```sh
DB=~/Library/Application\ Support/Doppler/Library.dopplerdb/Contents/library
sqlite3 -readonly "$DB" .tables
sqlite3 -readonly "$DB" 'PRAGMA table_info(ZSNRSONG);'
sqlite3 -readonly "$DB" 'SELECT Z_NAME, Z_ENT, Z_MAX FROM Z_PRIMARYKEY;'
```
