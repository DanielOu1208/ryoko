import SwiftUI

/// Saved Mimo chats in a sidebar the chat slides aside to reveal (design §4.9:
/// transcripts stay on the device). Search and New chat at the top, then the
/// chats by title, most recent first. Tap a chat to open it; touch and hold
/// to delete it.
struct MimoHistorySidebar: View {
    let chats: [MimoChatSummary]
    /// The chat on screen, if it has any messages.
    let currentID: String?
    var onOpen: (String) -> Void
    var onNewChat: () -> Void
    var onDelete: (String) -> Void

    @State private var query = ""
    @FocusState private var isSearching: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.grid * 2) {
            HStack(spacing: Theme.grid) {
                searchField
                Button("New chat", systemImage: "square.and.pencil", action: onNewChat)
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, Theme.grid * 2)

            if chats.isEmpty {
                ContentUnavailableView(
                    "No chats yet",
                    systemImage: "bubble.left",
                    description: Text("Your chats with Mimo stay on this phone.")
                )
            } else if filtered.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        Text("Chats")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, Theme.grid * 1.5)
                            .padding(.bottom, Theme.grid / 2)
                        ForEach(filtered) { chat in
                            row(chat)
                        }
                    }
                    .padding(.horizontal, Theme.grid)
                    .padding(.bottom, Theme.grid * 2)
                }
                .scrollDismissesKeyboard(.immediately)
            }
        }
        .padding(.top, Theme.grid)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Self.background)
    }

    /// The sidebar's colour, which also fades over the edge of the chat.
    static let background = Color(uiColor: .systemBackground)

    private var filtered: [MimoChatSummary] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return chats }
        return chats.filter { $0.title.localizedStandardContains(needle) }
    }

    private var searchField: some View {
        HStack(spacing: Theme.grid) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search", text: $query)
                .focused($isSearching)
                .submitLabel(.search)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.grid * 1.5)
        .frame(minHeight: 40)
        .background(Color(uiColor: .tertiarySystemFill), in: .capsule)
    }

    private func row(_ chat: MimoChatSummary) -> some View {
        let isCurrent = chat.id == currentID
        return Button {
            onOpen(chat.id)
        } label: {
            Text(chat.title)
                .lineLimit(1)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.grid * 1.5)
                .padding(.vertical, Theme.grid * 1.25)
                .background {
                    if isCurrent {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(uiColor: .tertiarySystemFill))
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Delete", systemImage: "trash", role: .destructive) { onDelete(chat.id) }
        }
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}
