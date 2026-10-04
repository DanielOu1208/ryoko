import SwiftUI

/// Picks a new time for the current preview (design §4.2): now to 7 days
/// ahead, in the place's time zone, with Morning, Afternoon and Evening chips.
/// Nothing changes until "Preview" commits the time.
struct PreviewTimeSheet: View {
    let situation: Situation

    @Environment(AppSituationStore.self) private var situationStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var date: Date
    private let range: ClosedRange<Date>
    private let zone: TimeZone

    /// The quick chips from design §4.2. Each time is glued to its AM/PM.
    private static let quickTimes: [(label: String, hour: Int)] = [
        ("Morning 9\u{00A0}AM", 9),
        ("Afternoon 3\u{00A0}PM", 15),
        ("Evening 7\u{00A0}PM", 19),
    ]

    init(situation: Situation, now: Date = .now) {
        self.situation = situation
        let range = now...now.addingTimeInterval(7 * 24 * 60 * 60)
        self.range = range
        zone = situation.zone ?? .current
        _date = State(initialValue: min(max(situation.date ?? now, range.lowerBound), range.upperBound))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(
                        "Date and time",
                        selection: $date,
                        in: range,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                } footer: {
                    Text("Times are local to \(situation.city).")
                }
                Section("Quick times") {
                    ChipFlowLayout(spacing: Theme.grid) {
                        ForEach(Self.quickTimes, id: \.hour) { quick in
                            chip(quick.label, hour: quick.hour)
                        }
                    }
                    .padding(.vertical, Theme.grid / 2)
                }
            }
            // The picker shows and edits the place's wall clock, not the device's.
            .environment(\.timeZone, zone)
            .navigationTitle("Pick a time")
            .navigationSubtitle(situation.place?.name ?? situation.city)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Preview", action: commit)
                }
            }
        }
        .presentationDetents(dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large])
    }

    private func chip(_ label: String, hour: Int) -> some View {
        let isSelected = isAt(hour: hour)
        return Button {
            date = Self.date(atHour: hour, near: date, in: zone, within: range)
        } label: {
            if isSelected {
                Label(label, systemImage: "checkmark")
            } else {
                Text(label)
            }
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func isAt(hour: Int) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return parts.hour == hour && parts.minute == 0
    }

    /// `hour`:00 on the selected day in `zone`; the next day if that's already
    /// past, the day before if it's beyond the range.
    static func date(atHour hour: Int, near selected: Date, in zone: TimeZone, within range: ClosedRange<Date>) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard var candidate = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: selected) else {
            return selected
        }
        if candidate < range.lowerBound, let next = calendar.date(byAdding: .day, value: 1, to: candidate) {
            candidate = next
        } else if candidate > range.upperBound, let previous = calendar.date(byAdding: .day, value: -1, to: candidate) {
            candidate = previous
        }
        return min(max(candidate, range.lowerBound), range.upperBound)
    }

    /// Re-previews the same place at the new time.
    private func commit() {
        if let place = situation.place {
            let preview = SituationPreview(
                place: place,
                date: date,
                timeZone: zone,
                city: situation.city,
                district: situation.district,
                countryCode: situation.countryCode
            )
            // The situation doesn't keep the subdivision: carry a Quebec preview's French over.
            let subdivision = situation.countryCode == "CA" && situation.localLanguage == "fr" ? "QC" : nil
            situationStore.startPreview(preview, subdivision: subdivision)
        }
        dismiss()
    }
}

/// Lays chips out left to right and wraps to a new line when the next one
/// doesn't fit, so they stay capsules at every text size. A chip wider than
/// the line wraps its own text between words.
private struct ChipFlowLayout: Layout {
    var spacing: CGFloat

    private struct Row {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y + (row.height - item.size.height) / 2),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            let needed = row.items.isEmpty ? size.width : row.width + spacing + size.width
            if needed > width, !row.items.isEmpty {
                rows.append(row)
                row = Row(items: [(index, size)], width: size.width, height: size.height)
            } else {
                row.items.append((index, size))
                row.width = needed
                row.height = max(row.height, size.height)
            }
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}
