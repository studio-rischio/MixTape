import SwiftUI

/// Tab 3 — Create. The counterpart to Discover: instead of the model inventing
/// themes from the library, the user describes an occasion, mood or activity
/// ("Italian dinner night", "biking trip") and gets one playlist built for it.
///
/// Gated exactly like `ShowcaseView` — LM Studio configured, library picked,
/// metadata cache synced — because it runs the same two-pass pipeline and would
/// fail in the same ways without them.
///
/// Results accumulate newest-first rather than replacing each other, so a user
/// can try several phrasings and compare before adding one to Doppler. They live
/// in `ShowcaseGenerator.entries` alongside Discover's, tagged `.created`, which
/// is what lets `ShowcaseDetailSheet`, Add to Doppler and Export .m3u work here
/// with no changes.
struct CreateView: View {
    @State private var settings = AppSettings.shared
    @State private var metadataCache = MetadataCache.shared
    @State private var generator = ShowcaseGenerator.shared
    @State private var brief: String = ""
    @State private var detailContext: DetailContext?
    @State private var mode: Mode = .describe
    @State private var seedQuery: String = ""
    @State private var seedResults: [Song] = []

    /// Two ways to get a playlist here. They're grouped in one tab because both
    /// are user-initiated ("I want *this*"), unlike Discover where the model
    /// decides. They share the results grid and the track-count setting.
    enum Mode: CaseIterable, Hashable {
        /// Describe it in words; two LLM passes, as in Discover.
        case describe
        /// Pick a track; collaborative filtering, no LLM at all.
        case similar

        var label: String {
            switch self {
            case .describe: "Describe"
            case .similar: "More like this"
            }
        }
    }

    private struct DetailContext: Identifiable {
        let id: UUID
    }

    /// Shown as placeholder rotation fodder and as tappable starters when the tab
    /// is empty — a blank text box gives no clue about the kind of thing that works.
    private static let examples = [
        "Italian dinner night",
        "Long biking trip",
        "Rainy Sunday morning",
        "Late-night drive home",
        "Focused deep work",
        "Cooking with friends",
    ]

    var body: some View {
        Group {
            if settings.libraryURL == nil {
                ContentUnavailableView {
                    Label("No Doppler library selected", systemImage: "music.note.house")
                } description: {
                    Text("Created playlists are built from music you already own.")
                } actions: {
                    SettingsLink { Text("Open Settings") }
                        .buttonStyle(.borderedProminent)
                }
            } else if !metadataCache.hasCompletedInitialSync {
                ContentUnavailableView {
                    Label("Building your library context", systemImage: "hourglass")
                } description: {
                    Text("Creating playlists unlocks once the initial MusicBrainz sync finishes. Check the banner on My Library.")
                        .multilineTextAlignment(.center)
                }
            } else {
                readyState
            }
        }
        .sheet(item: $detailContext) { ctx in
            ShowcaseDetailSheet(entryID: ctx.id)
        }
    }

    private var readyState: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Create").font(.title2.bold())
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(statusIsError ? Theme.warning : .secondary)
                        .lineLimit(2)
                }
                Spacer()
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(generator.isCreating)
            }

            // The LLM gate lives here rather than replacing the whole screen: the
            // mode picker above must stay reachable, or a user with LM Studio
            // closed can't switch to the mode that doesn't need it.
            if mode == .describe && !settings.isLLMConfigured {
                HStack(spacing: 10) {
                    Image(systemName: "lock.fill").foregroundStyle(Theme.warning)
                    Text("Describing a playlist needs a model. Pick one in Settings, or switch to “More like this” — it doesn't use the LLM.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    SettingsLink { Text("Open Settings") }
                }
                .padding(12)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.panelBorder))
            } else if mode == .similar {
                similarControls
            } else {
                describeControls
            }

            if generator.isCreating {
                progressBar
            }
        }
        .padding(20)
    }

    private var describeControls: some View {
        HStack(spacing: 10) {
                // Both settings are shared with Discover — and both genuinely apply
                // here, so they're shown rather than silently taking effect.
                Picker("", selection: Binding(
                    get: { settings.familiarity },
                    set: { settings.familiarity = $0 }
                )) {
                    ForEach(AppSettings.Familiarity.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .help(settings.familiarity.help)
                .disabled(generator.isCreating)

                Stepper(
                    value: Binding(
                        get: { settings.tracksPerPlaylist },
                        set: { settings.tracksPerPlaylist = $0 }
                    ),
                    in: 10...150,
                    step: 5
                ) {
                    Text("~\(settings.tracksPerPlaylist)")
                        .monospacedDigit()
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .help("Target tracks per playlist (10–150).")
                .disabled(generator.isCreating)
                .fixedSize()

                TextField("Describe a mood, occasion or activity…", text: $brief, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                    .font(.body)
                    .disabled(generator.isCreating)
                    // Submit on Return so the common case never needs the mouse.
                    .onSubmit(submit)

                if generator.isCreating {
                    Button("Cancel", role: .destructive) { generator.cancelCreate() }
                } else {
                    Button(action: submit) {
                        Label("Create", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
        }
    }

    /// Track picker for "More like this". Searching is debounced through
    /// `DopplerLibrary.findSongs(matching:)`; picking a result starts the walk
    /// immediately, since there's nothing else to configure.
    private var similarControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Stepper(
                    value: Binding(
                        get: { settings.tracksPerPlaylist },
                        set: { settings.tracksPerPlaylist = $0 }
                    ),
                    in: 10...150,
                    step: 5
                ) {
                    Text("~\(settings.tracksPerPlaylist)")
                        .monospacedDigit()
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .help("Target tracks per playlist (10–150).")
                .disabled(generator.isCreating)
                .fixedSize()

                TextField("Search your library for a track…", text: $seedQuery)
                    .textFieldStyle(.roundedBorder)
                    .disabled(generator.isCreating)

                if generator.isCreating {
                    Button("Cancel", role: .destructive) { generator.cancelCreate() }
                }
            }

            if !seedResults.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(seedResults) { song in
                            Button {
                                startSimilar(song)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "sparkle.magnifyingglass")
                                        .foregroundStyle(Theme.amber)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(song.title).lineLimit(1)
                                        Text(song.artist ?? "Unknown artist")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                            .disabled(generator.isCreating)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 180)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.panelBorder))
            }
        }
        // Debounced so a fast typist doesn't fire a query per keystroke.
        .task(id: seedQuery) {
            let q = seedQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard q.count >= 2, let url = settings.libraryURL else {
                seedResults = []
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let lib = DopplerLibrary(bundleURL: url)
            do {
                try await lib.openReadOnly()
                let found = try await lib.findSongs(matching: q)
                await lib.close()
                guard !Task.isCancelled else { return }
                seedResults = Array(found.prefix(25))
            } catch {
                await lib.close()
                seedResults = []
            }
        }
    }

    private func startSimilar(_ song: Song) {
        guard let url = settings.libraryURL, !generator.isCreating else { return }
        seedQuery = ""
        seedResults = []
        generator.createSimilar(seedTitle: song.title, seedArtist: song.artist, libraryURL: url)
    }

    /// Determinate where we can honestly measure progress (three known passes when
    /// describing; tracks-found-so-far when walking similarity), indeterminate
    /// otherwise. A spinner sits alongside so there's still motion when the bar is
    /// parked during a long LLM call — the model can take tens of seconds and a
    /// frozen bar reads as a hang.
    private var progressBar: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 4) {
                if let progress = generator.createPhase.progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
                if let status = generator.createPhase.status {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.top, 2)
        .transition(.opacity)
    }

    private var statusText: String {
        switch generator.createPhase {
        case .idle:
            if !generator.createdEntries.isEmpty {
                return "\(generator.createdEntries.count) playlist\(generator.createdEntries.count == 1 ? "" : "s") created this session"
            }
            return mode == .similar
                ? "Pick a track and it'll find music you own that goes with it."
                : "Describe what you want and it'll build a playlist from music you own."
        case .working:
            // The live status lives under the progress bar; don't say it twice.
            return "Working…"
        case .failed(let msg):
            return "Failed: \(msg)"
        }
    }

    private var statusIsError: Bool {
        if case .failed = generator.createPhase { return true }
        return false
    }

    @ViewBuilder
    private var content: some View {
        if generator.createdEntries.isEmpty && !generator.isCreating {
            emptyState
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 260, maximum: 400), spacing: 16)],
                    spacing: 16
                ) {
                    ForEach(generator.createdEntries) { entry in
                        Button {
                            detailContext = DetailContext(id: entry.id)
                        } label: {
                            ShowcaseTile(entry: entry)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if mode == .similar {
            ContentUnavailableView {
                Label("Nothing created yet", systemImage: "sparkle.magnifyingglass")
            } description: {
                Text("Search for a track above. You'll get songs you own that other listeners play alongside it — no LLM involved.\n\nWorks best with well-known tracks: ListenBrainz has little or no listening data for obscure artists.")
                    .multilineTextAlignment(.center)
            }
        } else {
            describeEmptyState
        }
    }

    private var describeEmptyState: some View {
        ContentUnavailableView {
            Label("Nothing created yet", systemImage: "text.bubble")
        } description: {
            Text("Try one of these, or write your own.")
        } actions: {
            // Starters double as documentation — they show the *kind* of phrasing
            // that works better than any placeholder string could.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 8)], spacing: 8) {
                ForEach(Self.examples, id: \.self) { example in
                    Button(example) {
                        brief = example
                        submit()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: 520)
        }
    }

    private func submit() {
        let trimmed = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !generator.isCreating, let url = settings.libraryURL else { return }
        generator.create(brief: trimmed, libraryURL: url)
        brief = ""
    }
}

#Preview {
    CreateView()
        .frame(width: 900, height: 600)
        .preferredColorScheme(.dark)
}
