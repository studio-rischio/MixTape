import Foundation

/// Read-only client for the MusicBrainz Web Service v2.
/// Anonymous use: 1 req/sec, must include a descriptive User-Agent.
/// https://musicbrainz.org/doc/MusicBrainz_API
///
/// Stateless `struct` — `searchArtist(name:)` is async and can be called from
/// any isolation context. Rate limiting is the *caller's* responsibility (see
/// `MetadataCache.runSync`'s `Task.sleep(for: .seconds(1))` between calls).
struct MusicBrainzClient: Sendable {
    /// User-Agent header — MusicBrainz blocks requests without a descriptive UA.
    /// The format `name/version (+contact)` is what their etiquette docs ask for.
    static let userAgent = "MixTape/1.0 (+https://github.com/studio-rischio/MixTape)"
    static let baseURL = URL(string: "https://musicbrainz.org/ws/2")!
    /// MB returns 0–100 match scores; below this we treat the result as "not found".
    static let minMatchScore = 80

    /// Substrings we treat as "this candidate looks like a musical artist". Used to
    /// disambiguate ties — e.g., MB returns the German voice actor named "Beck"
    /// ahead of the musician with the same score=100. If the top hit has none of
    /// these in its tags, we fall through to the next viable candidate that does.
    /// Substring (not exact) match because tags include things like "alternative
    /// rock", "indie pop", etc. — sub-genres still contain the root keyword.
    private static let musicTagHints: [String] = [
        "rock", "pop", "jazz", "metal", "electronic", "folk",
        "hip hop", "hip-hop", "rap", "country", "blues", "classical",
        "indie", "punk", "soul", "funk", "reggae", "dance", "house",
        "techno", "ambient", "alternative", "shoegaze", "synth",
        "disco", "garage", "r&b", "lo-fi", "world", "afrobeat",
    ]

    /// Joins the tags (delimiter doesn't matter for substring search) and looks
    /// for any music-genre hint. The whole point is to *not* match generic words
    /// like "actor" or "audiobook".
    private static func tagsLookMusical(_ tags: [String]) -> Bool {
        guard !tags.isEmpty else { return false }
        let joined = tags.joined(separator: "|").lowercased()
        return musicTagHints.contains { joined.contains($0) }
    }

    enum Error: LocalizedError {
        case http(Int)
        case decode(String)
        case network(String)
        case rateLimited

        var errorDescription: String? {
            switch self {
            case .http(let s): return "MusicBrainz returned HTTP \(s)."
            case .decode(let m): return "Couldn't read MusicBrainz response: \(m)"
            case .network(let m): return "Couldn't reach MusicBrainz: \(m)"
            case .rateLimited: return "MusicBrainz rate-limited the request."
            }
        }
    }

    /// The slice of MB metadata we actually persist into the cache. `mbid` is the
    /// stable MusicBrainz UUID; `disambiguation` is MB's one-liner ("alt rock,
    /// multi-instrumentalist"); `tags` are the top genre tags by user count.
    struct ArtistResult: Sendable {
        let mbid: String
        let name: String
        let disambiguation: String?
        let type: String?
        let country: String?
        let tags: [String]
        let score: Int
    }

    /// Decodable shape of the `/ws/2/artist?query=...&fmt=json` response. Only
    /// fields we use are spelled out; MB's response has many more we don't need.
    private struct SearchResponse: Decodable {
        let artists: [Artist]?
        struct Artist: Decodable {
            let id: String
            let name: String
            let disambiguation: String?
            let type: String?
            let country: String?
            let score: Int?
            let tags: [Tag]?
            struct Tag: Decodable {
                let count: Int?
                let name: String
            }
        }
    }

    /// Looks up an artist by name. Returns `nil` if no candidate scored above
    /// `minMatchScore` (80). Otherwise picks the best candidate, with a
    /// disambiguation pass that prefers candidates whose tags look musical
    /// (see `tagsLookMusical`) — handles the "Beck the voice actor vs Beck the
    /// musician" class of ambiguity. Throws `Error.rateLimited` on 429/503,
    /// `Error.network` on transport failures.
    func searchArtist(name: String) async throws -> ArtistResult? {
        // Quote the name and strip embedded quotes — MB's Lucene-style query syntax
        // doesn't escape them gracefully.
        let cleaned = name.replacingOccurrences(of: "\"", with: " ")
        let query = "artist:\"\(cleaned)\""

        var components = URLComponents(
            url: Self.baseURL.appendingPathComponent("artist"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: "10"),
        ]

        guard let url = components.url else {
            throw Error.network("invalid URL for artist=\(name)")
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        Log.debug("MB GET \(url.absoluteString)", category: LogCategory.process)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw Error.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw Error.http(-1)
        }
        if http.statusCode == 503 || http.statusCode == 429 {
            throw Error.rateLimited
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Error.http(http.statusCode)
        }

        let decoded: SearchResponse
        do {
            decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        } catch {
            throw Error.decode(error.localizedDescription)
        }

        let viable = (decoded.artists ?? []).filter { ($0.score ?? 0) >= Self.minMatchScore }
        guard let top = viable.first else {
            let bestScore = decoded.artists?.first?.score ?? 0
            Log.debug("MB best score \(bestScore) < \(Self.minMatchScore) for artist=\(name)", category: LogCategory.process)
            return nil
        }

        // Prefer the highest-scored candidate whose tags look musical. If none of the
        // viable candidates have any musical tags, fall back to the top hit.
        let chosen: SearchResponse.Artist
        if let withMusic = viable.first(where: { Self.tagsLookMusical(($0.tags ?? []).map(\.name)) }) {
            if withMusic.id != top.id {
                Log.info(
                    "MB disambiguated \"\(name)\": chose \(withMusic.id) (\(withMusic.name)) over top hit \(top.id) (\(top.name)) on musical tags",
                    category: LogCategory.process
                )
            }
            chosen = withMusic
        } else {
            chosen = top
        }

        let topTags: [String] = (chosen.tags ?? [])
            .sorted { ($0.count ?? 0) > ($1.count ?? 0) }
            .prefix(5)
            .map(\.name)

        return ArtistResult(
            mbid: chosen.id,
            name: chosen.name,
            disambiguation: chosen.disambiguation,
            type: chosen.type,
            country: chosen.country,
            tags: topTags,
            score: chosen.score ?? 0
        )
    }
}
