import SwiftUI

extension EnvironmentValues {
    /// The app's one place resolver. MapKit allows about 50 searches a minute for
    /// the whole app, so Map and Mimo share this instance (and its cache and
    /// throttle) instead of making their own. `RyokoApp` sets it; W4 swaps in the
    /// MapKit resolver there. Previews get the fixture resolver.
    @Entry var placeResolver: any PlaceResolver = FixturePlaceResolver()

    /// Speaks phrases (tier 2). `RyokoApp` sets `LiveSpeechService`. Previews
    /// get the fixture, which only logs.
    @Entry var speechService: any SpeechService = FixtureSpeechService()
}
