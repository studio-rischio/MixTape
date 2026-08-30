// DebugLogView.swift
//
// In-app log viewer. Reads the shared LogStore (see Log.swift) and renders
// entries with category/level filters, a text search, auto-scroll, and buttons
// for Copy / Save / Clear. Hosted in its own Window scene, opened via
// File → Debug Log (⌘⌥L).

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Debug log window contents. Stateful filters are local to the view; entries
/// live in the shared `LogStore` singleton and survive window open/close.
struct DebugLogView: View {
    @State private var store = LogStore.shared
    @State private var selectedCategories: Set<String> = []
    @State private var minLevel: LogLevel = .debug
    @State private var search: String = ""
    @State private var autoScroll: Bool = true

    private static let categories = LogCategory.all

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            logList
        }
    }

    private var toolbar: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("Min level", selection: $minLevel) {
                    Text("Debug").tag(LogLevel.debug)
                    Text("Info").tag(LogLevel.info)
                    Text("Warning").tag(LogLevel.warning)
                    Text("Error").tag(LogLevel.error)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 320)
                .help("Only show entries at this level or higher.")

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filter messages…", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .help("Case-insensitive substring match against each entry's message.")
                }
                .frame(maxWidth: 260)

                Spacer()

                Toggle("Auto-scroll", isOn: $autoScroll)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("Automatically scroll to the newest entry as it arrives.")

                Button("Copy to Clipboard") { copyToClipboard() }
                    .help("Copy the currently visible (filtered) entries to the clipboard.")
                Button("Save to File…") { saveToFile() }
                    .help("Save the currently visible (filtered) entries to a text file.")
                Button("Clear", role: .destructive) { store.clear() }
                    .help("Empty the in-memory log. Does not clear the system log.")
            }

            HStack(spacing: 6) {
                Text("Categories:").font(.caption).foregroundStyle(.secondary)
                ForEach(Self.categories, id: \.self) { cat in
                    Toggle(isOn: Binding(
                        get: { selectedCategories.isEmpty || selectedCategories.contains(cat) },
                        set: { on in
                            if selectedCategories.isEmpty {
                                selectedCategories = Set(Self.categories).subtracting([cat])
                                if !on { return }
                                selectedCategories.insert(cat)
                                if selectedCategories.count == Self.categories.count {
                                    selectedCategories = []
                                }
                            } else {
                                if on { selectedCategories.insert(cat) }
                                else { selectedCategories.remove(cat) }
                                if selectedCategories.count == Self.categories.count {
                                    selectedCategories = []
                                }
                            }
                        }
                    )) {
                        Text(cat).font(.caption)
                    }
                    .toggleStyle(.button)
                    .controlSize(.mini)
                }
                Spacer()
                Text("\(filtered.count) of \(store.entries.count) entries")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(10)
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filtered) { entry in
                        row(entry).id(entry.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: filtered.last?.id) { _, newId in
                guard autoScroll, let newId else { return }
                withAnimation(.linear(duration: 0.05)) {
                    proxy.scrollTo(newId, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ entry: LogEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(timestamp(entry.timestamp))
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            Text(entry.level.rawValue.uppercased())
                .font(.caption.monospaced())
                .foregroundStyle(color(for: entry.level))
                .frame(width: 52, alignment: .leading)
            Text(entry.category)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 66, alignment: .leading)
            Text(entry.message)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .primary
        case .warning: return .orange
        case .error: return .red
        }
    }

    private var filtered: [LogEntry] {
        let activeCats = selectedCategories.isEmpty ? Set(Self.categories) : selectedCategories
        let q = search.lowercased()
        return store.entries.filter { entry in
            guard entry.level >= minLevel else { return false }
            guard activeCats.contains(entry.category) else { return false }
            if !q.isEmpty && !entry.message.lowercased().contains(q) { return false }
            return true
        }
    }

    private func copyToClipboard() {
        let text = exportText()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func saveToFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd-HHmmss"
        panel.nameFieldStringValue = "doppler-smart-playlists-log-\(df.string(from: Date())).txt"
        if panel.runModal() == .OK, let url = panel.url {
            try? exportText().write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func exportText() -> String {
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return filtered.map { e in
            "\(df.string(from: e.timestamp)) [\(e.level.rawValue.uppercased())] \(e.category): \(e.message)"
        }.joined(separator: "\n")
    }
}
