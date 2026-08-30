import SwiftUI

/// Banner card for the metadata-cache sync phase. Lives at the top of My Doppler
/// while MusicBrainz lookups are running, failed, or cancelled. Hidden in the
/// idle/completed cases.
///
/// Pure presentation — owns no state. The parent passes `phase` (so the icon /
/// title / progress bar reflect the current step), `cachedCount` (used in the
/// cancelled-state subtitle), and an `onCancel` closure. Border color and
/// content adapt to the phase.
struct SyncBanner: View {
    let phase: MetadataCache.Phase
    let cachedCount: Int
    let onCancel: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            iconView
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if case .syncing(_, let processed, let total, _) = phase {
                    ProgressView(value: Double(processed), total: Double(max(total, 1)))
                        .progressViewStyle(.linear)
                }
            }
            Spacer(minLength: 8)
            actionButton
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(borderColor, lineWidth: 1)
        )
    }

    private var iconView: some View {
        Image(systemName: iconName)
            .font(.title2)
            .foregroundStyle(iconColor)
            .frame(width: 28)
    }

    private var iconName: String {
        switch phase {
        case .idle, .completed: "checkmark.seal"
        case .syncing: "arrow.triangle.2.circlepath"
        case .failed: "exclamationmark.triangle"
        case .cancelled: "xmark.circle"
        }
    }

    private var iconColor: Color {
        switch phase {
        case .syncing: Theme.lightPurple
        case .failed: .orange
        case .cancelled: .secondary
        case .idle, .completed: .green
        }
    }

    private var title: String {
        switch phase {
        case .idle: "Metadata cache idle"
        case .syncing(.artists, let p, let t, _): "Caching MusicBrainz metadata · \(p) of \(t)"
        case .syncing(.recordings, let p, let t, _): "Matching tracks · \(p) of \(t)"
        case .completed: "Metadata cache up to date"
        case .failed: "Metadata cache failed"
        case .cancelled: "Metadata cache cancelled"
        }
    }

    private var detail: String? {
        switch phase {
        case .syncing(.artists, _, _, let current):
            return current.isEmpty ? "Starting…" : "Looking up “\(current)”"
        case .syncing(.recordings, _, _, let current):
            // Batched, so "current" is just the head of the batch — say so rather
            // than implying we're on that one track.
            return current.isEmpty ? "Matching your tracks to MusicBrainz…" : "Around “\(current)”"
        case .failed(let msg):
            return msg
        case .cancelled:
            return "\(cachedCount) artists cached so far. Refresh to resume."
        case .idle, .completed:
            return nil
        }
    }

    private var background: Color { Theme.panel }

    private var borderColor: Color {
        switch phase {
        case .syncing: Theme.lightPurple.opacity(0.45)
        case .failed: .orange.opacity(0.5)
        case .cancelled: Theme.lavender.opacity(0.25)
        case .idle, .completed: Theme.panelBorder
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch phase {
        case .syncing:
            Button("Cancel", role: .destructive, action: onCancel)
        case .failed, .cancelled, .idle, .completed:
            EmptyView()
        }
    }
}
