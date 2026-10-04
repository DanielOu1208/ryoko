import os
import SwiftUI

/// Me's editor for one survey page (design §4.10): the survey's own form,
/// with changes saved as they're made. Each change goes through
/// `ProfileStore`, which recomputes `profile.version`.
///
/// Typed text (the diet notes, the home base's local name) is saved once
/// typing pauses for a second, on Return, or when the editor closes, never per
/// keystroke: every profile version reloads the Map's picks, Nearby's card and
/// the Live Activity, each a new server generation (design §7.4).
///
/// A skipped page (`null`) stays skipped until something is picked. "Mark as
/// skipped" turns an answered page back into `null`; for diet and allergies,
/// "None" records an explicit empty list (design §7.2: `[]` means none).
struct ProfileEditor: View {
    let page: SurveyPage

    @State private var draft: SurveyDraft
    /// Typed text waiting to be saved.
    @State private var pendingSave: Task<Void, Never>?
    @Environment(ProfileStore.self) private var profileStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(page: SurveyPage, profile: Profile) {
        self.page = page
        var draft = SurveyDraft(profile: profile)
        // A skipped page shows nothing picked (the survey's redo pre-fills the
        // home language; here that would look like a saved answer).
        if profile.spokenLanguages == nil { draft.spokenLanguages = [] }
        _draft = State(initialValue: draft)
    }

    var body: some View {
        SurveyPageForm(page: page, draft: $draft, context: .editor) {
            answerStateSection
        }
        .navigationTitle(page.title(for: dynamicTypeSize))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: draft) { old, edited in
            if edited.differsOnlyInTypedText(from: old) {
                saveWhenTypingPauses(edited)
            } else {
                save(edited)
            }
        }
        .onSubmit(savePendingText)
        .onDisappear(perform: savePendingText)
        #if DEBUG
        .task {
            // `-RyokoMeEditSample 1`: take the sample answers as if tapped in (keeps the home base).
            guard OnboardingDebugOptions.meEditAppliesSample else { return }
            try? await Task.sleep(for: .seconds(1.5))
            var sample = OnboardingDebugOptions.sampleDraft
            sample.homeBase = draft.homeBase
            draft = sample
        }
        .task { await typeDebugText() }
        #endif
    }

    #if DEBUG
    /// `-RyokoMeEditType "<text>"`: types into the page's free-text field a
    /// character at a time, through the same binding the keyboard writes.
    private func typeDebugText() async {
        guard let text = OnboardingDebugOptions.meEditTypedText, page == .diet || page == .homeBase else { return }
        try? await Task.sleep(for: .seconds(1.5))
        var typed = ""
        for character in text {
            typed.append(character)
            if page == .diet { draft.dietNotes = typed } else { draft.homeBase?.localName = typed }
            try? await Task.sleep(for: .milliseconds(150))
        }
        RyokoLog.onboarding.info("Typed \(typed.count) characters into the \(String(describing: page), privacy: .public) editor")
    }
    #endif

    private var isSkipped: Bool { ProfileWording.isSkipped(page, in: profileStore.profile) }

    // MARK: Saving

    /// Saves the page's answer now (and any typed text with it).
    private func save(_ edited: SurveyDraft) {
        cancelPendingSave()
        profileStore.update { edited.apply(page, to: &$0) }
        RyokoLog.profile.info("Me saved \(String(describing: page), privacy: .public): profile \(profileStore.profile.version.prefix(12), privacy: .public)")
    }

    /// Saves typed text a second after the last keystroke.
    private func saveWhenTypingPauses(_ edited: SurveyDraft) {
        cancelPendingSave()
        pendingSave = Task {
            do {
                try await Task.sleep(for: .seconds(1))
            } catch {
                return // more typing, a pick, or the editor closed
            }
            guard !Task.isCancelled else { return }
            save(edited)
        }
    }

    /// Saves typed text that is still waiting (Return, or the editor closing).
    private func savePendingText() {
        guard pendingSave != nil else { return }
        save(draft)
    }

    private func cancelPendingSave() {
        pendingSave?.cancel()
        pendingSave = nil
    }

    @ViewBuilder
    private var answerStateSection: some View {
        if isSkipped {
            if page != .homeBase {
                Section {
                    if let noneTitle {
                        Button(noneTitle) {
                            save(draft)
                        }
                    }
                } footer: {
                    Text("Skipped, so Ryoko doesn't use it. Pick something above to answer it.")
                }
            }
        } else {
            Section {
                Button(page == .homeBase ? "Remove home base" : "Mark as skipped") {
                    cancelPendingSave()
                    profileStore.update { SurveyDraft.skip(page, in: &$0) }
                    dismiss()
                }
            } footer: {
                if page == .origin {
                    Text("Skipping clears your country and sets the home language to this device's.")
                } else if page != .homeBase {
                    Text("Ryoko stops using this until you answer it again.")
                }
            }
        }
    }

    /// The "none" answer for pages where nothing picked means none.
    private var noneTitle: String? {
        switch page {
        case .diet where draft.diet.isEmpty && draft.dietNotes.isEmpty: "Nothing to avoid"
        case .allergies where draft.allergies.isEmpty: "No allergies"
        default: nil
        }
    }
}

private extension SurveyDraft {
    /// True when the drafts differ only in typed text: the diet notes or the
    /// home base's local name.
    func differsOnlyInTypedText(from other: SurveyDraft) -> Bool {
        var mine = self
        var theirs = other
        mine.dietNotes = ""
        theirs.dietNotes = ""
        mine.homeBase?.localName = nil
        theirs.homeBase?.localName = nil
        return mine == theirs
    }
}
