#if DEBUG
import SwiftUI

/// DEBUG: the Live Activity's views as the lock screen and the Dynamic Island
/// show them, for checking the look from the command line (the simulator's lock
/// screen can't be reached without taps). The views are the extension's own,
/// from `Shared/RyokoActivityViews.swift`; the frames around them approximate
/// the system's.
///
///     xcrun simctl launch <udid> com.danielou.ryoko -RyokoActivityGallery 1
///
/// Add `-RyokoActivityGalleryDark 1` for the dark lock screen, and
/// `-RyokoScrollToBottom 1` to see the expanded island.
struct LiveActivityGallery: View {
    static var launchRequested: Bool {
        UserDefaults.standard.bool(forKey: "RyokoActivityGallery")
    }

    static var prefersDark: Bool {
        UserDefaults.standard.bool(forKey: "RyokoActivityGalleryDark")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                caption("Lock screen · preview, loading")
                lockScreen(ActivitySamples.tokyo, ActivitySamples.loading)
                caption("Lock screen · preview, phrase")
                lockScreen(ActivitySamples.tokyo, ActivitySamples.tokyoReady)
                caption("Lock screen · here, phrase")
                lockScreen(ActivitySamples.shanghai, ActivitySamples.shanghaiReady)
                caption("Lock screen · card unavailable")
                lockScreen(ActivitySamples.shanghai, ActivitySamples.unavailable)
                caption("Dynamic Island · compact and minimal")
                HStack(spacing: 12) {
                    compactIsland(ActivitySamples.shanghai)
                    minimalIsland(ActivitySamples.tokyo)
                }
                caption("Dynamic Island · expanded")
                expandedIsland(ActivitySamples.tokyo, ActivitySamples.tokyoReady)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 24)
        }
        .debugLaunchScrollAnchor()
        .background(Color(white: Self.prefersDark ? 0.12 : 0.55).ignoresSafeArea())
        .environment(\.colorScheme, Self.prefersDark ? .dark : .light)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.top, 4)
    }

    /// The lock screen draws a Live Activity on a system material, rounded.
    private func lockScreen(_ attributes: RyokoActivityAttributes, _ state: RyokoActivityAttributes.ContentState) -> some View {
        ActivityLockScreenView(attributes: attributes, state: state)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func compactIsland(_ attributes: RyokoActivityAttributes) -> some View {
        HStack {
            Image(systemName: attributes.categorySymbol)
            Spacer(minLength: 96) // the camera
            Text(attributes.shortPlaceName)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
        }
        .font(.subheadline)
        .padding(.horizontal, 14)
        .frame(height: 37)
        .background(.black, in: Capsule())
        .environment(\.colorScheme, .dark)
    }

    private func minimalIsland(_ attributes: RyokoActivityAttributes) -> some View {
        Image(systemName: attributes.categorySymbol)
            .font(.subheadline)
            .frame(width: 37, height: 37)
            .background(.black, in: Circle())
            .environment(\.colorScheme, .dark)
    }

    private func expandedIsland(_ attributes: RyokoActivityAttributes, _ state: RyokoActivityAttributes.ContentState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: attributes.categorySymbol)
                    .font(.title3)
                Spacer()
                Text(attributes.placeName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                ActivityClock(timeZoneID: attributes.timeZoneID)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ActivityPhraseLines(state: state, style: .island)
                .padding(.top, 4)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(.black, in: RoundedRectangle(cornerRadius: 44, style: .continuous))
        .environment(\.colorScheme, .dark)
    }
}

#Preview {
    LiveActivityGallery()
}
#endif
