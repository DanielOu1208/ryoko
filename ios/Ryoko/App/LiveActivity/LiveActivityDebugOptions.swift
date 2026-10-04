#if DEBUG
import Foundation
import os

/// DEBUG launch arguments for the Live Activity (design §4.11). There's no tap
/// automation, and the iOS 27 simulator asks "Open in Ryoko?" before
/// `simctl openurl` delivers a custom-scheme URL, so the deep link is driven
/// from the command line instead:
///
///     xcrun simctl launch <udid> com.danielou.ryoko \
///       -RyokoOpenURL 'ryoko://show?phrase=pc-tk-1'
///
/// - `-RyokoOpenURL <url>`: at launch, hand `url` to the same handler as
///   `onOpenURL` (`LiveActivityCoordinator.open(_:router:)`). On a fresh launch
///   this is the cold-start path: the phrase comes from the kept phrases.
/// - `-RyokoActivityGallery 1`: the Live Activity's views as the lock screen
///   and the Dynamic Island show them (`LiveActivityGallery`), with
///   `-RyokoActivityGalleryDark 1` for dark.
/// - `-RyokoActivityScript 1`: walks the coordinator through its cases, four
///   seconds apart, for its log (`category == "live-activity"`): preview the
///   Tokyo sample at 7 PM, the same place at 9 AM (an update, not a new
///   activity), the Shanghai fixture café (the old one ends, a new one starts),
///   then Back to here with no live place (it ends).
/// - `-RyokoActivityLifetime <seconds>`: a shorter lifetime than two hours.
nonisolated enum LiveActivityDebugOptions {
    static var openURLAtLaunch: URL? {
        UserDefaults.standard.string(forKey: "RyokoOpenURL").flatMap(URL.init(string:))
    }

    /// `-RyokoActivityLifetime <seconds>`: activities end after this long
    /// instead of two hours, to check the end of the two hours.
    static var lifetimeOverride: TimeInterval? {
        let seconds = UserDefaults.standard.double(forKey: "RyokoActivityLifetime")
        return seconds > 0 ? seconds : nil
    }

    static var runsScript: Bool {
        UserDefaults.standard.bool(forKey: "RyokoActivityScript")
    }

    @MainActor
    static func runScript(on situationStore: AppSituationStore) async {
        let step = Duration.seconds(4)
        RyokoLog.liveActivity.info("Script: Tokyo at 7 PM")
        situationStore.previewSample(hour: 19)
        try? await Task.sleep(for: step)
        RyokoLog.liveActivity.info("Script: Tokyo at 9 AM (same place)")
        situationStore.previewSample(hour: 9)
        try? await Task.sleep(for: step)
        if let shanghai = Fixtures.shanghai, let place = shanghai.place, let zone = shanghai.zone {
            RyokoLog.liveActivity.info("Script: Shanghai café (new place)")
            situationStore.startPreview(SituationPreview(
                place: place,
                date: .now,
                timeZone: zone,
                city: shanghai.city,
                district: shanghai.district,
                countryCode: shanghai.countryCode
            ))
        }
        try? await Task.sleep(for: step)
        RyokoLog.liveActivity.info("Script: back to here")
        situationStore.endPreview()
    }
}
#endif
