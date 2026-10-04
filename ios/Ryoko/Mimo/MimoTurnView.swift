import SwiftUI

/// One turn: your message, then Mimo's reply as ordered segments (design §4.9),
/// how it ended, and, once it's over, its sources.
struct MimoTurnView: View {
    let turn: MimoTurn
    /// Whether "Try again" can be offered now.
    let canRetry: Bool
    var onShowPhrase: (Phrase) -> Void
    var onSelectPlace: (MimoFoundPlace) -> Void
    var onShowOnMap: (MimoPlaces) -> Void
    var onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.grid * 2) {
            MimoUserBubble(text: turn.message)
            VStack(alignment: .leading, spacing: Theme.grid * 1.5) {
                ForEach(displayOrder, id: \.self) { index in
                    segmentView(turn.segments[index])
                        .id(MimoTurnView.segmentID(turn: turn.id, index: index))
                        .transition(.opacity)
                }
                ending
                // Sources come last, once the reply is over: a search runs
                // before Mimo writes, but its sources shouldn't sit above
                // sentences still streaming in.
                if showsSources {
                    MimoSourcesView(sources: turn.sources)
                        .padding(.top, Theme.grid / 2)
                        .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.35), value: displayOrder)
            .animation(.smooth(duration: 0.35), value: showsSources)
        }
    }

    private var showsSources: Bool {
        !turn.sources.isEmpty && !turn.isStreaming
    }

    /// The segments' indices in the order they're shown. Mimo calls
    /// `show_places` before it writes, so a reply can open with a places card;
    /// that card is shown after the first text instead, once that text is
    /// finished (something follows it, or the reply ends), so the sentence
    /// introduces the places and nothing streams in above them. Everything
    /// else keeps its order.
    private var displayOrder: [Int] {
        var order: [Int] = []
        var pendingPlaces: [Int] = []
        var hasText = false
        for (index, segment) in turn.segments.enumerated() {
            switch segment {
            case .places where !hasText:
                pendingPlaces.append(index)
            case .text where segment.hasVisibleContent:
                hasText = true
                order.append(index)
                let isFinished = index < turn.segments.count - 1 || !turn.isStreaming
                if isFinished {
                    order += pendingPlaces
                    pendingPlaces = []
                }
            default:
                order.append(index)
            }
        }
        return order + (turn.isStreaming ? [] : pendingPlaces)
    }

    /// A scroll target for one segment.
    static func segmentID(turn: UUID, index: Int) -> String {
        "\(turn.uuidString)-\(index)"
    }

    @ViewBuilder
    private func segmentView(_ segment: MimoSegment) -> some View {
        switch segment {
        case let .text(text):
            MimoTextView(text: text, revealsGradually: turn.isStreaming)
        case let .phrase(phrase):
            MimoPhraseLine(phrase: phrase, onShow: { onShowPhrase(phrase) })
        case let .places(places):
            MimoPlacesView(places: places, onSelect: onSelectPlace, onShowOnMap: { onShowOnMap(places) })
        case .sources:
            EmptyView() // collected under the reply
        }
    }


    @ViewBuilder
    private var ending: some View {
        switch turn.status {
        case .streaming:
            EmptyView()
        case let .done(reason):
            if reason != .stop {
                quietNote("Reply cut short", systemImage: "ellipsis.circle")
            }
        case .stopped:
            HStack(spacing: Theme.grid * 1.5) {
                quietNote("Stopped", systemImage: "stop.circle")
                if canRetry { retryButton }
            }
        case let .failed(failure):
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.grid * 1.5) { failureContent(failure) }
                VStack(alignment: .leading, spacing: Theme.grid) { failureContent(failure) }
            }
        }
    }

    @ViewBuilder
    private func failureContent(_ failure: MimoFailure) -> some View {
        Label(failure.message, systemImage: failure.isSessionBusy ? "hourglass" : "exclamationmark.circle")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        if failure.retryable, canRetry {
            retryButton
        }
    }

    private var retryButton: some View {
        Button("Try again", action: onRetry)
            .font(.footnote.weight(.semibold))
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
    }

    private func quietNote(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.footnote)
            .foregroundStyle(.tertiary)
    }
}

extension MimoTurn {
    /// What Mimo is doing while the reply streams, for the status pill:
    /// thinking before anything arrives, the tool's own line while a tool runs
    /// ("Searching the web…"), working while it writes. Nil once it's over.
    var statusLine: String? {
        guard isStreaming else { return nil }
        if let toolLine { return toolLine }
        return segments.contains(where: \.hasVisibleContent) ? "Working…" : "Thinking…"
    }
}

private extension MimoSegment {
    /// Whether this segment shows anything yet (text can be only whitespace).
    var hasVisibleContent: Bool {
        if case let .text(text) = self {
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }
}

// MARK: - Your message

private struct MimoUserBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.body)
            .padding(.horizontal, Theme.grid * 2)
            .padding(.vertical, Theme.grid * 1.25)
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, Theme.grid * 6)
            .textSelection(.enabled)
            .accessibilityLabel("You: \(text)")
    }
}

// MARK: - Text

/// Mimo's sentences, with inline Markdown only (bold, italics, code, links).
struct MimoTextView: View {
    let text: String
    /// While the reply streams: show the text at a steady pace as it arrives,
    /// instead of in the bursts the network delivers it in.
    var revealsGradually = false

    /// How many characters show; nil shows them all (a saved reply).
    @State private var revealed: Int?

    var body: some View {
        let shown = revealed.map { String(text.prefix($0)) } ?? text
        let trimmed = shown.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(Self.markdown(trimmed))
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .task(id: text.count) {
                    if revealsGradually, revealed == nil { revealed = 0 }
                    await catchUp()
                }
        }
    }

    /// Reveals towards the full text, a few characters a frame, faster when
    /// it's further behind, so a burst eases in instead of jumping.
    private func catchUp() async {
        while let shown = revealed, shown < text.count, !Task.isCancelled {
            let behind = text.count - shown
            revealed = min(text.count, shown + max(2, behind / 10))
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

// MARK: - Sources

/// Web sources under the reply, as links (design §4.9).
private struct MimoSourcesView: View {
    let sources: [WebSource]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.grid * 0.75) {
            Label("Searched the web", systemImage: "globe")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack(spacing: Theme.grid * 0.75) {
                    ForEach(onePerSite, id: \.url) { source in
                        if let url = source.link {
                            Link(destination: url) {
                                Text(Self.siteName(url) ?? source.title)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .padding(.horizontal, Theme.grid * 1.25)
                                    .padding(.vertical, Theme.grid / 2)
                                    .background(Color(uiColor: .tertiarySystemFill), in: .capsule)
                            }
                            .foregroundStyle(.primary)
                            .accessibilityLabel(source.title)
                            .accessibilityHint("Opens in Safari")
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    /// The first source from each site: two pages from one site are one pill.
    private var onePerSite: [WebSource] {
        var seen = Set<String>()
        return sources.filter { source in
            guard let url = source.link else { return false }
            return seen.insert(Self.siteName(url) ?? source.url).inserted
        }
    }

    /// "tabelog.com" from "https://www.tabelog.com/…".
    private static func siteName(_ url: URL) -> String? {
        url.host()?.replacingOccurrences(of: "www.", with: "")
    }
}
