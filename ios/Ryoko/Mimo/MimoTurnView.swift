import SwiftUI

/// One turn: your message, then Mimo's reply as ordered segments (design §4.9),
/// the quiet tool line while it streams, how it ended, and its sources.
struct MimoTurnView: View {
    let turn: MimoTurn
    let showsRomanization: Bool
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
                ForEach(Array(turn.segments.enumerated()), id: \.offset) { index, segment in
                    segmentView(segment)
                        .id(MimoTurnView.segmentID(turn: turn.id, index: index))
                }
                activity
                ending
                if !turn.sources.isEmpty {
                    MimoSourcesView(sources: turn.sources)
                        .padding(.top, Theme.grid / 2)
                }
            }
        }
    }

    /// A scroll target for one segment.
    static func segmentID(turn: UUID, index: Int) -> String {
        "\(turn.uuidString)-\(index)"
    }

    @ViewBuilder
    private func segmentView(_ segment: MimoSegment) -> some View {
        switch segment {
        case let .text(text):
            MimoTextView(text: text)
        case let .phrase(phrase):
            PhraseCardView(
                phrase: phrase,
                style: .block,
                showsRomanization: showsRomanization,
                onShow: { onShowPhrase(phrase) }
            )
        case let .places(places):
            MimoPlacesView(places: places, onSelect: onSelectPlace, onShowOnMap: { onShowOnMap(places) })
        case .sources:
            EmptyView() // collected under the reply
        }
    }

    /// While streaming: the tool line, or a quiet "replying" mark before
    /// anything has arrived.
    @ViewBuilder
    private var activity: some View {
        if turn.isStreaming {
            if let toolLine = turn.toolLine {
                HStack(spacing: Theme.grid) {
                    ProgressView()
                        .controlSize(.small)
                    Text(toolLine)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
            } else if !turn.segments.contains(where: \.hasVisibleContent) {
                Image(systemName: "ellipsis")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                    .accessibilityLabel("Mimo is replying")
            }
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

    var body: some View {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            Text(Self.markdown(trimmed))
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
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
        VStack(alignment: .leading, spacing: Theme.grid) {
            Text("Sources")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(sources, id: \.url) { source in
                if let url = source.link {
                    Link(destination: url) {
                        HStack(alignment: .firstTextBaseline, spacing: Theme.grid) {
                            Image(systemName: "arrow.up.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.title)
                                    .font(.subheadline)
                                    .multilineTextAlignment(.leading)
                                if let host = url.host() {
                                    Text(host.replacingOccurrences(of: "www.", with: ""))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .foregroundStyle(.primary)
                    .accessibilityHint("Opens in Safari")
                }
            }
        }
    }
}
