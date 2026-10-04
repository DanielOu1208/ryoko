/// What Mimo is doing, for the avatar. The app sets it; the avatar morphs between moods
/// through the engine's own transitions (exponential ease-outs, a blink on each shape
/// change).
///
/// | Mood        | bloub states and cycle                                                          |
/// | ----------- | ------------------------------------------------------------------------------- |
/// | `idle`      | `idle` with the rest expression: gaze drift and scheduled blinks, nothing else  |
/// | `listening` | `idle`, the head turns towards the user with the listening expression           |
/// | `thinking`  | loops `thinking` (three dots, 3 s) and `orbit` (spinning body and rings, 1.8 s) |
/// | `talking`   | `idle` with small nods of the gaze while text streams                           |
/// | `happy`     | a `wink`, then `idle` with the happy expression, then the rest expression       |
///
/// `happy` plays once and settles: it looks like `idle` afterwards, so the app can leave it
/// set until the next message.
nonisolated enum MimoMood: String, CaseIterable, Hashable, Sendable {
    case idle
    case listening
    case thinking
    case talking
    case happy
}
