import ActivityKit
import SwiftUI
import WidgetKit

/// The Live Activity for the active place (design §4.11). The views are in
/// `Shared/RyokoActivityViews.swift`; this wires them into the lock screen and
/// the Dynamic Island, and links every tap to Show mode for the phrase
/// (`ryoko://show?phrase=<id>`), or to Nearby while there's no phrase yet.
///
/// - Lock screen: place name, local time, the top phrase and its gloss.
/// - Dynamic Island: compact is the category symbol and a short place name,
///   minimal is the symbol, expanded is the phrase.
struct RyokoLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RyokoActivityAttributes.self) { context in
            ActivityLockScreenView(attributes: context.attributes, state: context.state)
                .widgetURL(RyokoDeepLink(phrase: context.state.phrase).url)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.attributes.categorySymbol)
                        .font(.title3)
                        .accessibilityHidden(true)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ActivityClock(timeZoneID: context.attributes.timeZoneID)
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.placeName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ActivityPhraseLines(state: context.state, style: .island)
                        .padding(.top, 4)
                }
            } compactLeading: {
                Image(systemName: context.attributes.categorySymbol)
                    .accessibilityLabel(context.attributes.placeName)
            } compactTrailing: {
                // `shortPlaceName` is at most 12 characters, so it needs no width cap.
                Text(context.attributes.shortPlaceName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } minimal: {
                Image(systemName: context.attributes.categorySymbol)
                    .accessibilityLabel(context.attributes.placeName)
            }
            .widgetURL(RyokoDeepLink(phrase: context.state.phrase).url)
            .keylineTint(.primary)
        }
    }
}

#if DEBUG
#Preview("Lock screen", as: .content, using: ActivitySamples.tokyo) {
    RyokoLiveActivity()
} contentStates: {
    ActivitySamples.loading
    ActivitySamples.tokyoReady
}

#Preview("Lock screen, live", as: .content, using: ActivitySamples.shanghai) {
    RyokoLiveActivity()
} contentStates: {
    ActivitySamples.shanghaiReady
    ActivitySamples.unavailable
}

#Preview("Island expanded", as: .dynamicIsland(.expanded), using: ActivitySamples.tokyo) {
    RyokoLiveActivity()
} contentStates: {
    ActivitySamples.tokyoReady
}

#Preview("Island compact", as: .dynamicIsland(.compact), using: ActivitySamples.shanghai) {
    RyokoLiveActivity()
} contentStates: {
    ActivitySamples.shanghaiReady
}

#Preview("Island minimal", as: .dynamicIsland(.minimal), using: ActivitySamples.tokyo) {
    RyokoLiveActivity()
} contentStates: {
    ActivitySamples.tokyoReady
}
#endif
