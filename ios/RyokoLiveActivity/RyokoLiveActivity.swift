import ActivityKit
import SwiftUI
import WidgetKit

struct RyokoLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RyokoActivityAttributes.self) { context in
            LockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.attributes.categorySymbol)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    LocalTimeText(timeZoneID: context.attributes.timeZoneID)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.placeName)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 2) {
                        Text(context.state.phraseLocal).font(.headline)
                        Text(context.state.phraseGloss).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: context.attributes.categorySymbol)
            } compactTrailing: {
                Text(context.attributes.placeName)
                    .lineLimit(1)
                    .frame(maxWidth: 64)
            } minimal: {
                Image(systemName: context.attributes.categorySymbol)
            }
        }
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<RyokoActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: context.attributes.categorySymbol)
                Text(context.attributes.placeName).font(.headline).lineLimit(1)
                Spacer()
                LocalTimeText(timeZoneID: context.attributes.timeZoneID)
                    .font(.caption)
            }
            Text(context.state.phraseLocal).font(.title3)
            Text(context.state.phraseGloss).font(.caption).foregroundStyle(.secondary)
        }
        .padding()
    }
}

private struct LocalTimeText: View {
    let timeZoneID: String

    var body: some View {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        return Text(Date.now, format: style)
    }
}
