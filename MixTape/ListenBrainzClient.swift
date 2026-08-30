import Foundation

/// Read-only client for the ListenBrainz "labs" dataset hoster and the main
/// ListenBrainz API.
///
/// Why this exists alongside `MusicBrainzClient`: MusicBrainz's web service is
/// **1 req/sec and one entity per request**, which makes per-track lookups
/// impractical (a 3,000-track library would take ~50 minutes). ListenBrainz
/// exposes the same identity data through **batch POST endpoints that need no
/// API key and no rate limiting**, turning the same job into a handful of
/// requests. Don't copy `MusicBrainzClient`'s `Task.sleep(for: .seconds(1))`
/// here — it isn't needed, and it would make the sync 100x slower than it has to be.
///
/// Two endpoints are used:
/// - `acr-lookup` maps `(artist name, track title)` → MusicBrainz identifiers.
/// - `/1/popularity/recording` maps recording MBIDs → global listen counts.
///
/// **The canonical-MBID trap.** A song has many recordings in MusicBrainz (album,
/// single, remaster, live), and the ListenBrainz datasets are keyed on exactly one
/// *canonical* recording MBID. `acr-lookup` returns that canonical one; a MusicBrainz
/// `/ws/2/recording?query=` search returns whichever recording matched, which is
/// usually a *different, equally valid* MBID that every ListenBrainz dataset will
/// return empty for. Verified against "Knives Out" by Radiohead: the search MBID
/// gave `total_listen_count: null`, the canonical MBID gave 1,250,106. **Always
/// take MBIDs from `acr-lookup`** — a naive implementation looks like "there is no
/// data" rather than "you asked with the wrong ID".
struct ListenBrainzClient: Sendable {
    /// Same descriptive UA as the MusicBrainz client — MetaBrainz runs both and
    /// asks for a contactable identifier on all of them.
    static let userAgent = MusicBrainzClient.userAgent
    static let labsBaseURL = URL(string: "https://labs.api.listenbrainz.org")!
    static let apiBaseURL = URL(string: "https://api.listenbrainz.org")!

    /// How many items to send per request. Verified that `acr-lookup` accepts at
    /// least 1000 in one call, but smaller batches keep the sync's progress bar
    /// moving and bound the damage from any single failed request.
    static let batchSize = 200

    enum Error: LocalizedError {
        case http(Int)
        case decode(String)
        case network(String)

        var errorDescription: String? {
            switch self {
            case .http(let s): return "ListenBrainz returned HTTP \(s)."
            case .decode(let m): return "Couldn't read ListenBrainz response: \(m)"
            case .network(let m): return "Couldn't reach ListenBrainz: \(m)"
            }
        }
    }

    /// One resolved track identity. `listenCount`/`userCount` are filled in by a
    /// separate `popularity` call and stay nil until then.
    struct RecordingMatch: Sendable {
        let recordingMBID: String
        let artistMBID: String?
        let releaseMBID: String?
        let releaseName: String?
    }

    struct Popularity: Sendable {
        let listenCount: Int?
        let userCount: Int?
    }

    // MARK: - acr-lookup

    /// Decodable row from `acr-lookup`. `index` is the caller's position in the
    /// request array — the response comes back **out of order**, and unmatched
    /// inputs are **silently omitted** rather than returned as nulls, so the index
    /// is the only reliable way to line results up with what was asked.
    private struct ACRRow: Decodable {
        let index: Int
        let recording_mbid: String?
        let artist_mbids: [String]?
        let release_mbid: String?
        let release_name: String?
    }

    /// Resolves up to `batchSize` `(artist, title)` pairs to canonical MusicBrainz
    /// identifiers in a single request. Returns a dictionary keyed by the *input
    /// index*; absent keys are inputs ListenBrainz couldn't match, which the caller
    /// should record as a negative cache entry so they aren't retried forever.
    func lookupRecordings(_ pairs: [(artist: String, title: String)]) async throws -> [Int: RecordingMatch] {
        guard !pairs.isEmpty else { return [:] }
        let body = pairs.map { ["artist_credit_name": $0.artist, "recording_name": $0.title] }
        let rows: [ACRRow] = try await postJSON(
            url: Self.labsBaseURL.appendingPathComponent("acr-lookup/json"),
            body: body
        )
        var result: [Int: RecordingMatch] = [:]
        for row in rows {
            guard let mbid = row.recording_mbid else { continue }
            result[row.index] = RecordingMatch(
                recordingMBID: mbid,
                artistMBID: row.artist_mbids?.first,
                releaseMBID: row.release_mbid,
                releaseName: row.release_name
            )
        }
        return result
    }

    // MARK: - title cleanup for retrying misses

    /// Parenthetical suffixes that describe *packaging* rather than a different
    /// performance — the same recording, remastered or re-mixed or credited with a
    /// guest. Falling back to the bare title for these is safe: the underlying
    /// recording is the one we want.
    ///
    /// Deliberately **excludes** "live", "remix", "acoustic", "demo" and "cover".
    /// Those are genuinely different recordings, and silently resolving
    /// "Song (Live)" to the studio take would attach the wrong listen counts to it
    /// — which would then quietly corrupt any familiarity/popularity feature built
    /// on this cache. Better to leave those unmatched than to match them wrongly.
    /// Matched as **whole words**, never as substrings. Substring matching looked
    /// fine until you meet a real title: "(Rising with the Tide)" contains "with",
    /// "(Mixtape Intro)" contains "mix". Stripping those resolves the song to a
    /// different recording and attaches the wrong listen counts to it.
    ///
    /// "with" is deliberately absent even as a word — it appears in ordinary
    /// English far too often, and "feat"/"featuring"/"ft" already cover the guest
    /// credits it was meant to catch.
    private static let packagingTokens: Set<String> = [
        "remaster", "remastered", "remasters", "mix", "mixes", "version",
        "edit", "mono", "stereo", "bonus", "deluxe", "reissue",
        "anniversary", "edition", "explicit", "clean",
        "feat", "featuring", "ft", "featuring.",
    ]

    /// Markers of a genuinely different performance. Checked *first* and as a veto,
    /// because parentheticals combine: "(Demo - Bonus)" contains "bonus" and would
    /// otherwise pass the packaging test and resolve a demo to the studio take,
    /// attaching that recording's listen counts to the wrong track.
    private static let performanceTokens: Set<String> = [
        "live", "remix", "remixes", "acoustic", "demo", "demos", "cover",
        "session", "sessions", "unplugged", "instrumental", "karaoke",
        "rehearsal", "alternate", "outtake", "reprise",
    ]

    /// Splits on anything that isn't a letter or digit, so "feat." → ["feat"],
    /// "Remastered 2011" → ["remastered", "2011"], "Blue Morpho (Ciel's Flutter)"
    /// inner → ["ciel", "s", "flutter"].
    private static func words(_ s: String) -> [String] {
        s.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// True if a parenthetical's contents look like packaging noise rather than
    /// part of the actual title — i.e. any whole word in it is a packaging token
    /// and none is a performance token. Real values that must match: "2022 Mix",
    /// "Remastered 2011", "featuring Dennis Hopper", "Deluxe Edition".
    private static func isPackagingNoise(_ inner: String) -> Bool {
        let tokens = Set(words(inner))
        guard !tokens.isEmpty else { return true }
        // Veto wins over any packaging token also present in the same group, so
        // "(Demo - Bonus)" is left alone rather than resolving to the studio take.
        if !tokens.isDisjoint(with: performanceTokens) { return false }
        return !tokens.isDisjoint(with: packagingTokens)
    }

    /// Strips trailing packaging parentheticals from a title so a missed lookup can
    /// be retried. Returns `nil` when there's nothing to strip, so callers can skip
    /// pointless second requests.
    ///
    /// Only **trailing** groups are removed, which keeps titles like
    /// "(Don't Fear) The Reaper" intact, and only when the contents match
    /// `packagingTokens`, which keeps "Blue Morpho (Ciel's Flutter)" intact.
    /// Also collapses runs of whitespace — real libraries contain things like
    /// "Babe I'm Gonna Leave You  (Remaster)" with a double space.
    static func strippedTitle(_ title: String) -> String? {
        var working = title.trimmingCharacters(in: .whitespaces)

        var changed = true
        while changed {
            changed = false
            guard let last = working.last else { break }
            let closers: [Character: Character] = [")": "(", "]": "["]
            guard let opener = closers[last],
                  let openIdx = working.lastIndex(of: opener)
            else { break }
            let inner = working[working.index(after: openIdx)..<working.index(before: working.endIndex)]
            guard Self.isPackagingNoise(String(inner)) else { break }
            working = String(working[working.startIndex..<openIdx]).trimmingCharacters(in: .whitespaces)
            changed = true
        }

        // Trailing dash form: "Song - 2011 Remaster", common in tags written by
        // tools that import from streaming services.
        if let dash = working.range(of: " - ", options: .backwards) {
            let tail = String(working[dash.upperBound...])
            if Self.isPackagingNoise(tail) {
                working = String(working[working.startIndex..<dash.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
        }

        let collapsed = working.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty, collapsed != title else { return nil }
        return collapsed
    }

    // MARK: - popularity

    private struct PopularityRow: Decodable {
        let recording_mbid: String
        let total_listen_count: Int?
        let total_user_count: Int?
    }

    /// Global listen/user counts for a batch of **canonical** recording MBIDs.
    /// This is what makes "hidden gems" vs "greatest hits" possible, and it's
    /// orthogonal to the user's own `ZSONGPLAYHISTORY` counts: crossing the two
    /// separates "famous song you never play" from "obscure song you play constantly".
    func popularity(recordingMBIDs: [String]) async throws -> [String: Popularity] {
        guard !recordingMBIDs.isEmpty else { return [:] }
        let rows: [PopularityRow] = try await postJSON(
            url: Self.apiBaseURL.appendingPathComponent("1/popularity/recording"),
            body: ["recording_mbids": recordingMBIDs]
        )
        var result: [String: Popularity] = [:]
        for row in rows {
            result[row.recording_mbid] = Popularity(
                listenCount: row.total_listen_count,
                userCount: row.total_user_count
            )
        }
        return result
    }

    // MARK: - similar recordings

    /// Default similarity dataset. ListenBrainz offers several; this one is built
    /// from a long listening window with a listener cap, and gave the most sensible
    /// results when spot-checked ("Knives Out" → Thom Yorke "Harrowdown Hill").
    static let defaultSimilarityAlgorithm =
        "session_based_days_7500_session_300_contribution_5_threshold_15_limit_50_skip_30_top_n_listeners_1000"

    struct SimilarRecording: Sendable {
        let recordingMBID: String
        let recordingName: String
        let artistCreditName: String
        /// Which seed this came back for. The endpoint accepts many seeds at once
        /// and flattens the results, so this is the only way to tell them apart.
        let referenceMBID: String
        let score: Int
    }

    private struct SimilarRow: Decodable {
        let recording_mbid: String?
        let recording_name: String?
        let artist_credit_name: String?
        let reference_mbid: String?
        let score: Int?
    }

    /// Collaboratively-filtered "listeners who played this also played…" for one or
    /// more seed recordings.
    ///
    /// **GET, with `recording_mbids` repeated once per seed.** The POST form 400s,
    /// and a comma-separated list fails UUID validation — verified both. Repeating
    /// the parameter batches the whole frontier of a similarity walk into one
    /// request, which is what makes expansion cheap.
    ///
    /// Seeds must be **canonical** MBIDs from `acr-lookup`; anything else returns
    /// an empty list. Coverage is uneven by design — well-listened artists return
    /// 50–100 similar recordings, while obscure ones return nothing at all, so
    /// callers must handle "no data" as a normal outcome rather than an error.
    func similarRecordings(
        to seedMBIDs: [String],
        algorithm: String = defaultSimilarityAlgorithm
    ) async throws -> [SimilarRecording] {
        guard !seedMBIDs.isEmpty else { return [] }
        var components = URLComponents(
            url: Self.labsBaseURL.appendingPathComponent("similar-recordings/json"),
            resolvingAgainstBaseURL: false
        )
        var items = seedMBIDs.map { URLQueryItem(name: "recording_mbids", value: $0) }
        items.append(URLQueryItem(name: "algorithm", value: algorithm))
        components?.queryItems = items
        guard let url = components?.url else { throw Error.network("couldn't build similarity URL") }

        let rows: [SimilarRow] = try await getJSON(url: url)
        return rows.compactMap { row in
            guard let mbid = row.recording_mbid, let ref = row.reference_mbid else { return nil }
            return SimilarRecording(
                recordingMBID: mbid,
                recordingName: row.recording_name ?? "",
                artistCreditName: row.artist_credit_name ?? "",
                referenceMBID: ref,
                score: row.score ?? 0
            )
        }
    }

    // MARK: - transport

    private func getJSON<Response: Decodable>(url: URL) async throws -> Response {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            // URLSession reports task cancellation as URLError.cancelled, not as
            // CancellationError. Wrapping it in Error.network would make callers'
            // `catch is CancellationError` miss, turning a user-initiated cancel
            // into an error banner.
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw Error.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw Error.network("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Error.http(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw Error.decode(error.localizedDescription)
        }
    }

    private func postJSON<Body: Encodable, Response: Decodable>(
        url: URL,
        body: Body
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            // URLSession reports task cancellation as URLError.cancelled, not as
            // CancellationError. Wrapping it in Error.network would make callers'
            // `catch is CancellationError` miss, turning a user-initiated cancel
            // into an error banner.
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw Error.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw Error.network("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Error.http(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw Error.decode(error.localizedDescription)
        }
    }
}
