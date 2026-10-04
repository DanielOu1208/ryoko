import SwiftUI
import os

extension RyokoLog {
    nonisolated static let onboarding = Logger(subsystem: subsystem, category: "onboarding")
}

// MARK: - Chips

/// Lays chips out in rows, wrapping to the next row when one is full. A chip
/// wider than the row (large accessibility sizes) gets the row's width and
/// wraps its own text.
struct SurveyChipLayout: Layout {
    var spacing: CGFloat = 8 // Theme.grid

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y + (row.height - item.size.height) / 2),
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, width maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            if size.width > maxWidth {
                size = subviews[index].sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
                size.width = min(size.width, maxWidth)
            }
            let needed = row.items.isEmpty ? size.width : row.width + spacing + size.width
            if needed > maxWidth, !row.items.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append((index, size))
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}

/// A capsule chip (design §4.1: bordered/prominent buttons as chips). Selected
/// chips are prominent, in the monochrome tint.
struct SurveyChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Group {
            if isSelected {
                button.buttonStyle(.monochromeProminent)
            } else {
                button.buttonStyle(.bordered)
            }
        }
        .buttonBorderShape(.capsule)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .sensoryFeedback(.selection, trigger: isSelected)
    }

    private var button: some View {
        Button(action: action) {
            Text(title)
                .multilineTextAlignment(.leading)
        }
    }
}

/// A wrapping group of chips for a multi-select list, in a form row.
struct ChipGroup<Value: Hashable>: View {
    let values: [Value]
    let title: (Value) -> String
    let isSelected: (Value) -> Bool
    let toggle: (Value) -> Void

    var body: some View {
        SurveyChipLayout {
            ForEach(values, id: \.self) { value in
                SurveyChip(title: title(value), isSelected: isSelected(value)) { toggle(value) }
            }
        }
        .padding(.vertical, Theme.grid / 2)
    }
}

/// A text field with an Add button, for typed-in chips (foods, drinks,
/// allergens). Adds on Return too, and clears itself.
struct AddItemField: View {
    let prompt: String
    let limit: Int
    let add: (String) -> Void

    @State private var text = ""

    var body: some View {
        HStack(spacing: Theme.grid * 1.5) {
            TextField(prompt, text: $text)
                .submitLabel(.done)
                .onSubmit(commit)
                .onChange(of: text) { _, new in
                    if new.count > limit { text = String(new.prefix(limit)) }
                }
            Button("Add", action: commit)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .disabled(SurveyOptions.cleaned(text, limit: limit) == nil)
        }
    }

    private func commit() {
        guard let item = SurveyOptions.cleaned(text, limit: limit) else { return }
        add(item)
        text = ""
    }
}

// MARK: - Continue

/// True while a page shows search suggestions (the home base search), so the
/// survey hides Continue instead of covering them.
nonisolated struct SurveyHidesContinueKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

/// The survey's glass-prominent Continue button (design §4.1), full width at
/// the bottom of each page. In the monochrome tint the system would draw the
/// label in white on white in dark mode, so the label takes the background
/// colour instead (as `MonochromeProminentButtonStyle` does).
struct SurveyContinueButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .foregroundStyle(Color(uiColor: .systemBackground))
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .tint(Theme.tint)
        .padding(.horizontal, Theme.margin)
        .padding(.bottom, Theme.grid)
    }
}
