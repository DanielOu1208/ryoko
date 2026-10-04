import SwiftUI

/// Me's editor for one survey page (design §4.10): the survey's own form,
/// with changes saved as they're made. Each change goes through
/// `ProfileStore`, which recomputes `profile.version`.
///
/// A skipped page (`null`) stays skipped until something is picked. "Mark as
/// skipped" turns an answered page back into `null`; for diet and allergies,
/// "None" records an explicit empty list (design §7.2: `[]` means none).
struct ProfileEditor: View {
    let page: SurveyPage

    @State private var draft: SurveyDraft
    @Environment(ProfileStore.self) private var profileStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(page: SurveyPage, profile: Profile) {
        self.page = page
        _draft = State(initialValue: SurveyDraft(profile: profile))
    }

    var body: some View {
        SurveyPageForm(page: page, draft: $draft, context: .editor) {
            answerStateSection
        }
        .navigationTitle(page.title(for: dynamicTypeSize))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: draft) { _, edited in
            profileStore.update { edited.apply(page, to: &$0) }
        }
    }

    private var isSkipped: Bool { ProfileWording.isSkipped(page, in: profileStore.profile) }

    @ViewBuilder
    private var answerStateSection: some View {
        if isSkipped {
            if let noneTitle {
                Section {
                    Button(noneTitle) {
                        profileStore.update { draft.apply(page, to: &$0) }
                    }
                } footer: {
                    Text("You skipped this in the survey, so Ryoko doesn't use it.")
                }
            }
        } else {
            Section {
                Button(page == .homeBase ? "Remove home base" : "Mark as skipped") {
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
