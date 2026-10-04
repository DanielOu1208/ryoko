import SwiftUI

/// Mimo's animated avatar: a pebble-shaped body with two eyes, in the primary label
/// colour (black in light mode, white in dark). The eyes are holes that show the
/// background.
///
///     MimoAvatarView(mood: .thinking, size: 56)
///     MimoAvatarView(state: .orbit, frozenAt: 1.2, size: 72)   // one exact frame
///
/// `size` is the side of the square the avatar draws in. The frame keeps bloub's margin
/// for the orbit rings, so the body's diameter is about 0.63 times `size`. For Dynamic
/// Type, scale it at the call site: `@ScaledMetric(relativeTo: .title) var size = 56`.
///
/// Decorative by default (hidden from VoiceOver). Pass `accessibilityLabel` when the
/// avatar carries meaning on its own.
///
/// With Reduce Motion on, the avatar holds a still pose per mood and crossfades between
/// moods.
struct MimoAvatarView: View {
    private enum Content: Equatable {
        case mood(MimoMood)
        case frozen(Bloub.StateID, Double)
    }

    private let content: Content
    private let size: CGFloat
    private let style: MimoAvatarStyle
    private let label: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The live avatar, playing `mood`. Changing `mood` morphs to the new one.
    init(mood: MimoMood, size: CGFloat, style: MimoAvatarStyle = .mimo, accessibilityLabel: String? = nil) {
        content = .mood(mood)
        self.size = size
        self.style = style
        label = accessibilityLabel
    }

    /// One fixed frame: `state`, `frozenAt` seconds into it. No animation loop.
    init(state: Bloub.StateID, frozenAt: Double, size: CGFloat, style: MimoAvatarStyle = .mimo,
         accessibilityLabel: String? = nil)
    {
        content = .frozen(state, frozenAt)
        self.size = size
        self.style = style
        label = accessibilityLabel
    }

    var body: some View {
        avatar
            .frame(width: size, height: size)
            .modifier(MimoAvatarAccessibility(label: label))
    }

    @ViewBuilder private var avatar: some View {
        switch content {
        case let .frozen(state, t):
            MimoAvatarCanvas(frame: MimoAvatarDirector.frozen(state, at: t, style: style), style: style)
        case let .mood(mood):
            if reduceMotion {
                ZStack {
                    MimoAvatarCanvas(frame: MimoAvatarDirector.still(mood, style: style), style: style)
                        .id(mood)
                        .transition(.opacity)
                }
                .animation(.easeInOut(duration: 0.25), value: mood)
            } else {
                MimoLiveAvatar(mood: mood, style: style)
            }
        }
    }
}

/// The animation loop. The director keeps the engine and the mood schedule; the
/// timeline only asks it for the frame at each date.
private struct MimoLiveAvatar: View {
    var mood: MimoMood
    var style: MimoAvatarStyle
    @State private var director = MimoAvatarDirector()

    var body: some View {
        TimelineView(.animation) { timeline in
            MimoAvatarCanvas(frame: director.frame(at: timeline.date, mood: mood, style: style), style: style)
        }
    }
}

private struct MimoAvatarAccessibility: ViewModifier {
    var label: String?

    func body(content: Content) -> some View {
        if let label {
            content
                .accessibilityElement()
                .accessibilityLabel(Text(label))
                .accessibilityAddTraits(.isImage)
        } else {
            content.accessibilityHidden(true)
        }
    }
}

#Preview("Moods") {
    VStack(spacing: 24) {
        ForEach(MimoMood.allCases, id: \.self) { mood in
            HStack {
                MimoAvatarView(mood: mood, size: 72)
                Text(mood.rawValue).font(.headline)
                Spacer()
            }
        }
    }
    .padding(20)
}
