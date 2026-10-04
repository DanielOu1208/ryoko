/// Mimo's look, picked from bloub's own catalogue (shapes, expressions) so the motion
/// stays bloub's, measured off the reference video.
///
/// **Why `.mimo` is its own character and not the x.ai avatar.** bloub's default is the
/// x.ai bot: a perfect circle (`cercle`) whose eyes glance up and to the right, leaning
/// `\\` (`neutre`: yaw 28.5, pitch 28.6, roll -13). Mimo changes the two things that
/// carry that identity:
///
/// - **Body: `galet`, a pebble.** A circle bent by two low harmonics: lopsided, smooth
///   and organic, like a river stone. Its silhouette alone tells it apart from the
///   circle, even at tab-bar size.
/// - **Rest face: `attentif`.** Upright eyes that look at you (yaw 4, pitch 5), not past
///   you. A calm friend paying attention, which is what Mimo is.
///
/// Mimo also draws in the label colours only (design §9.2), not bloub's hue wheel or
/// its blue: the body, the dots and the notification dot in the primary label colour
/// (black in light mode, white in dark), the orbit rings and the comet's ribbons in the
/// secondary one. A ring that passes in front of the body is separated from it by a thin
/// cut, so it reads over the body in either mode.
///
/// The animated states (thinking dots, orbit, burst...) keep their measured silhouettes;
/// a chosen shape only replaces the body on bloub's `baseBody` states (idle, wink, wide,
/// notify, swirl), and bloub's eye-fit table re-seats the face on the pebble.
nonisolated struct MimoAvatarStyle: Hashable, Sendable {
    /// Body shape on the resting states.
    var shape: Bloub.ShapeID
    /// The rest face: idle and talking.
    var rest: Bloub.ExpressionID
    /// The face while the user is typing or speaking.
    var listening: Bloub.ExpressionID
    /// The face after a reply lands.
    var happy: Bloub.ExpressionID
    /// The label colour of the rings and ribbons.
    var ringTone: Tone
    /// The cut around a ring passing in front of the body, in ball radii.
    var ringGap: Double

    enum Tone: Hashable, Sendable {
        case primary
        case secondary
    }

    static let mimo = MimoAvatarStyle(shape: .galet, rest: .attentif, listening: .curieux, happy: .heureux,
                                      ringTone: .secondary, ringGap: 0.03)

    #if DEBUG
    /// bloub's default (the x.ai look), only to compare against in the DEBUG gallery.
    static let bloubDefault = MimoAvatarStyle(shape: .cercle, rest: .neutre, listening: .neutre, happy: .neutre,
                                              ringTone: .secondary, ringGap: 0.03)
    #endif

    var bodyShape: Bloub.BodyShape { shape.shape }
}
