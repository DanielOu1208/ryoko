import os
import SwiftUI

/// Where Me's navigation stack can go: Settings, or a survey page's editor.
enum MeRoute: Hashable {
    case settings
    case editor(SurveyPage)
}

/// The Me tab (design §4.10, #69). The home is about you at a glance:
/// - a header with your avatar (a symbol you pick), where you're from, the
///   languages you speak
/// - the allergy card, ready to show (tap it to open Show mode)
/// - diet, your usual and the home base, each opening its editor
/// - "About me" in your own words
/// - Settings, which holds the rest: every profile page, Redo survey, the
///   romanization toggle, credits and the developer section.
///
/// The blue wash sits behind the list. Every edit goes through
/// `ProfileStore`, so `profile.version` changes and the server's caches (keyed
/// on it) regenerate.
struct MeView: View {
    @Environment(ProfileStore.self) private var profileStore
    @State private var path: [MeRoute] = []
    @State private var isRedoingSurvey = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                MeHeader()
                MeAllergySection()
                MeGlanceSection()
                AboutMeSection()
                Section {
                    NavigationLink(value: MeRoute.settings) {
                        Label("Settings", systemImage: "gearshape")
                    }
                } footer: {
                    Text("Your full profile, Redo survey, display and developer options.")
                }
            }
            .listSectionSpacing(Theme.grid * 3)
            // The avatar sits just under the title, without the list's top gap.
            .contentMargins(.top, Theme.grid, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .background { SituationGradient() }
            .navigationTitle("Me")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: MeRoute.self) { route in
                switch route {
                case .settings:
                    MeSettingsView(isRedoingSurvey: $isRedoingSurvey)
                case .editor(let page):
                    ProfileEditor(page: page, profile: profileStore.profile)
                }
            }
        }
        .fullScreenCover(isPresented: $isRedoingSurvey) {
            SurveyFlowView(
                mode: .redo,
                draft: SurveyDraft(profile: profileStore.profile),
                onFinish: { profile in
                    profileStore.completeOnboarding(with: profile)
                    isRedoingSurvey = false
                },
                onCancel: { isRedoingSurvey = false }
            )
        }
        #if DEBUG
        .task {
            // `-RyokoMeEdit <page>|redo` and `-RyokoScrollToBottom 1` (screenshots).
            guard path.isEmpty else { return }
            if OnboardingDebugOptions.meRedoesSurvey {
                isRedoingSurvey = true
            } else if let page = OnboardingDebugOptions.meEditorPage {
                path = [.settings, .editor(page)]
            } else if DebugLaunchOptions.scrollAnchor != nil {
                path = [.settings]
            }
        }
        #endif
    }
}

// MARK: - About me

/// "About me": the traveller's own words about themselves (`profile.aboutMe`),
/// which Mimo, place cards and discover take as background.
///
/// Like Me's other typed text, it's saved once typing pauses for a second,
/// when the field loses focus, or when it goes off screen, never per
/// keystroke: every profile version reloads the Map's picks, Nearby's card and
/// the Live Activity, each a new server generation (design §7.4).
private struct AboutMeSection: View {
    /// The count shows from here on.
    private static let countFrom = Profile.aboutMeLimit - 100

    @Environment(ProfileStore.self) private var profileStore
    @State private var text = ""
    /// Typed text waiting to be saved.
    @State private var pendingSave: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    var body: some View {
        Section {
            TextField(
                "About me",
                text: $text,
                prompt: Text("Anything Mimo should know about you: how you like to travel, what you're into, who you're with"),
                axis: .vertical
            )
            .lineLimit(3...8)
            .focused($isFocused)
            .onChange(of: text) { _, typed in
                let capped = Profile.cappedAboutMe(typed)
                guard capped == typed else {
                    text = capped // pasted past the limit; this change saves
                    return
                }
                saveWhenTypingPauses()
            }
            .onChange(of: isFocused) { _, focused in
                if !focused { savePendingText() }
            }
            .onChange(of: profileStore.profile.aboutMe) { _, saved in
                // Changed elsewhere ("Reset to seed profile"): show that instead.
                guard Profile.cleanedAboutMe(text) != saved else { return }
                cancelPendingSave()
                text = saved ?? ""
            }
            .onAppear(perform: showSaved)
            .onDisappear(perform: savePendingText)
            .toolbar {
                if isFocused {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { isFocused = false }
                    }
                }
            }
            #if DEBUG
            .task { await typeDebugText() }
            #endif
        } header: {
            Text("About me")
        } footer: {
            footer
        }
    }

    private var footer: some View {
        let used = Profile.aboutMeLength(of: text)
        return HStack(alignment: .firstTextBaseline) {
            Text("Mimo uses this when it helps. Up to 500 characters.")
            if used >= Self.countFrom {
                Spacer(minLength: 8)
                Text("\(used)/\(Profile.aboutMeLimit)")
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .accessibilityLabel("\(used) of \(Profile.aboutMeLimit) characters")
            }
        }
    }

    // MARK: Saving

    /// The saved text, unless there's typing in progress.
    private func showSaved() {
        guard pendingSave == nil, !isFocused else { return }
        text = profileStore.profile.aboutMe ?? ""
    }

    /// Saves a second after the last keystroke, if the text changed.
    private func saveWhenTypingPauses() {
        cancelPendingSave()
        guard Profile.cleanedAboutMe(text) != profileStore.profile.aboutMe else { return }
        pendingSave = Task {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return // more typing, or the field went away
            }
            guard !Task.isCancelled else { return }
            save()
        }
    }

    /// Saves typed text that is still waiting (focus lost, or off screen).
    private func savePendingText() {
        guard pendingSave != nil else { return }
        save()
    }

    private func save() {
        cancelPendingSave()
        profileStore.setAboutMe(text)
        RyokoLog.profile.info("Me saved about me (\(Profile.aboutMeLength(of: text)) of \(Profile.aboutMeLimit)): profile \(profileStore.profile.version.prefix(12), privacy: .public)")
    }

    private func cancelPendingSave() {
        pendingSave?.cancel()
        pendingSave = nil
    }

    #if DEBUG
    /// `-RyokoMeAboutType "<text>"`: types into the field a character at a
    /// time, through the same binding the keyboard writes (replacing what's there).
    private func typeDebugText() async {
        guard let typedText = OnboardingDebugOptions.meAboutTypedText else { return }
        try? await Task.sleep(for: .seconds(1.5))
        var typed = ""
        for character in typedText {
            typed.append(character)
            text = typed
            try? await Task.sleep(for: .milliseconds(150))
        }
        RyokoLog.profile.info("Typed \(typed.count) characters into About me")
    }
    #endif
}

#Preview {
    MeView()
        .environment(ProfileStore.preview())
        .environment(APIStore())
        .environment(AppSituationStore.preview(nil))
        .environment(AppRouter())
}
