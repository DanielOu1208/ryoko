import SwiftUI
import os

/// Onboarding (design §4.1, tier 2): the survey runs full screen on first
/// launch only. Until it's answered the bundled seed profile drives
/// personalization; once it is, `ProfileStore.completeOnboarding(with:)`
/// saves the new profile (a new `version`, so server caches regenerate).
///
/// The app shell applies it once, inside the environment:
///
///     RootTabView()
///         .onboardingOnFirstLaunch()
///         .environment(profileStore)
extension View {
    /// Presents the survey full screen when the profile store hasn't been
    /// onboarded yet. DEBUG: see `OnboardingDebugOptions`.
    func onboardingOnFirstLaunch() -> some View {
        modifier(FirstLaunchOnboarding())
    }
}

private struct FirstLaunchOnboarding: ViewModifier {
    @Environment(ProfileStore.self) private var profileStore
    @State private var isPresented = false
    @State private var didCheck = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard !didCheck else { return }
                didCheck = true
                guard Self.shouldPresent(isOnboarded: profileStore.isOnboarded) else { return }
                // Already up when the app appears: no slide-in over the map.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { isPresented = true }
            }
            .fullScreenCover(isPresented: $isPresented) {
                SurveyFlowView(
                    mode: .firstLaunch,
                    draft: Self.initialDraft,
                    onFinish: { profile in
                        profileStore.completeOnboarding(with: profile)
                        RyokoLog.onboarding.info("Survey finished, profile \(profileStore.profile.version.prefix(12), privacy: .public)")
                        #if DEBUG
                        OnboardingDebugOptions.logProfile(profileStore.profile)
                        #endif
                        isPresented = false
                    },
                    onUseDemoProfile: demoProfileAction
                )
            }
    }

    /// DEBUG only: "Use demo profile" keeps the seed profile.
    private var demoProfileAction: (() -> Void)? {
        #if DEBUG
        return {
            profileStore.resetToSeed()
            profileStore.markOnboarded()
            RyokoLog.onboarding.info("Survey set aside; using the demo (seed) profile")
            isPresented = false
        }
        #else
        return nil
        #endif
    }

    private static var initialDraft: SurveyDraft {
        #if DEBUG
        if OnboardingDebugOptions.usesSample { return OnboardingDebugOptions.sampleDraft }
        #endif
        return .firstLaunch()
    }

    private static func shouldPresent(isOnboarded: Bool) -> Bool {
        #if DEBUG
        if let forced = OnboardingDebugOptions.forced { return forced }
        // Launches scripted with other -Ryoko… arguments go straight to their screen.
        if OnboardingDebugOptions.isScriptedLaunch { return false }
        #endif
        return !isOnboarded
    }
}
