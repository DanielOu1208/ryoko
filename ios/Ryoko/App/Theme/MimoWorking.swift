import SwiftUI
import ThinkingOrbs

/// What Mimo is working on, while it works (design §9.5, #65): a thinking orb
/// (`ThinkingOrbs`, after Jakub Antalik's thinking-orbs, MIT) over a short
/// line. Content only: the caller puts it on its card surface. The orb's
/// design says what kind of work it is:
///
/// - `.weaving`: picking places (several steps).
/// - `.composing`: writing (a place card's phrases and tips, an allergy card).
/// - `.connecting`: putting a reply's places on the map.
/// - `.searching`: finding where you are.
///
/// Busy buttons (the mic, Taxi, translating) keep the system spinner, which
/// fits inside a button.
struct MimoWorking: View {
    let design: OrbDesign
    /// Nil when something nearby already says it (a header).
    var line: String?

    var body: some View {
        VStack(spacing: Theme.grid * 1.5) {
            ThinkingOrb(design)
            if let line {
                Text(line)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .contentTransition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.grid * 3)
        .padding(.horizontal, Theme.cardPadding)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line ?? design.accessibilityLabel)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// Content that arrives as a stack of cards, after Mimo's working card: while
/// `isLoading`, one card with the orb (`working`); then it dissolves into the
/// first card in its place, and the rest rise in one by one. Each top-level
/// view of `content` is one step of the stack.
///
/// The working card and the content share the top of the stack (a `ZStack`),
/// so the card turns into the first card instead of pushing it down. The
/// stack only grows downwards, so nothing above it moves. Steps that arrive
/// later (picks coming in one at a time) rise in the same way.
///
/// Content that was already at hand (a saved card) just appears: the hand-off
/// plays only once the working card has been up long enough to be seen.
struct ArrivingStack<Working: View, Content: View>: View {
    let isLoading: Bool
    var spacing: CGFloat = Theme.cardSpacing
    @ViewBuilder var working: Working
    /// What arrives; empty while loading.
    @ViewBuilder var content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The working card has been on screen long enough to be seen.
    @State private var workingWasSeen = false

    var body: some View {
        ZStack(alignment: .top) {
            if isLoading {
                working
                    .transition(.orbDissolve)
            }
            Group(subviews: content) { steps in
                VStack(alignment: .leading, spacing: spacing) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        step.transition(workingWasSeen ? .arrives(at: index, reduceMotion: reduceMotion) : .identity)
                    }
                }
            }
        }
        .animation(workingWasSeen ? .smooth(duration: 0.45) : nil, value: isLoading)
        .task(id: isLoading) {
            // Kept once loading ends, so the hand-off can play.
            guard isLoading else { return }
            workingWasSeen = false
            try? await Task.sleep(for: .milliseconds(250))
            if !Task.isCancelled { workingWasSeen = true }
        }
    }
}

/// The working card's exit: it softens, swells a little and fades, as if its
/// dots were scattering.
struct OrbDissolve: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .opacity(phase.isIdentity ? 1 : 0)
            .blur(radius: phase.isIdentity ? 0 : 8)
            .scaleEffect(phase == .didDisappear ? 1.04 : 1)
    }
}

extension Transition where Self == OrbDissolve {
    static var orbDissolve: OrbDissolve { OrbDissolve() }
}

extension AnyTransition {
    /// A stack's step arriving: the first comes into focus where the working
    /// card was; the rest rise in after it, one by one. Leaving is a plain
    /// fade, all at once.
    static func arrives(at index: Int, reduceMotion: Bool) -> AnyTransition {
        let arrival: AnyTransition = if index == 0 || reduceMotion {
            .opacity
        } else {
            .opacity.combined(with: .offset(y: 16))
        }
        return .asymmetric(
            insertion: arrival.animation(.smooth(duration: 0.45).delay(reduceMotion ? 0 : Double(index) * 0.07)),
            removal: .opacity.animation(.smooth(duration: 0.2))
        )
    }
}
