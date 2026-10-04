import Observation
import SwiftUI

/// The survey's state: the draft, the page stack, and which pages were
/// answered (Continue) or skipped (Skip). Unanswered pages are stored as `null`.
@MainActor
@Observable
final class SurveyModel {
    enum Mode {
        /// The first launch: nothing to cancel back to.
        case firstLaunch
        /// Me → Redo survey, starting from the current answers.
        case redo
    }

    let mode: Mode
    var draft: SurveyDraft
    /// Pages 2–7 pushed over page 1.
    var path: [SurveyPage] = []
    private(set) var answered: Set<SurveyPage> = []
    /// Set once the last page is left; the flow saves and closes.
    private(set) var isFinished = false

    init(mode: Mode, draft: SurveyDraft) {
        self.mode = mode
        self.draft = draft
    }

    /// Continue: keeps the page's answer and moves on.
    func answer(_ page: SurveyPage) {
        answered.insert(page)
        advance(from: page)
    }

    /// Skip: the page is stored as `null`.
    func skip(_ page: SurveyPage) {
        answered.remove(page)
        advance(from: page)
    }

    /// The profile the survey produces (`version` is set by `ProfileStore`).
    var profile: Profile { draft.profile(answered: answered) }

    /// Opens a page directly, with the pages before it underneath (DEBUG
    /// screenshots). Earlier pages count as answered.
    func jump(to page: SurveyPage) {
        path = SurveyPage.allCases.filter { $0.rawValue > 1 && $0.rawValue <= page.rawValue }
        answered = Set(SurveyPage.allCases.filter { $0.rawValue < page.rawValue })
    }

    private func advance(from page: SurveyPage) {
        guard let next = page.next else {
            isFinished = true
            return
        }
        path = SurveyPage.allCases.filter { $0.rawValue > 1 && $0.rawValue <= next.rawValue }
    }
}

/// The onboarding survey (design §4.1): seven pages in a `NavigationStack`
/// with large titles, each skippable, with a glass-prominent Continue button.
/// About 45 seconds. Shown full screen on first launch, and from Me → Redo survey.
struct SurveyFlowView: View {
    @State private var model: SurveyModel
    /// Called with the finished profile; the presenter saves it and closes.
    let onFinish: (Profile) -> Void
    /// Redo only: closes without changing anything.
    var onCancel: (() -> Void)?
    /// DEBUG, first launch only: keep the seed (demo) profile.
    var onUseDemoProfile: (() -> Void)?

    init(
        mode: SurveyModel.Mode,
        draft: SurveyDraft,
        onFinish: @escaping (Profile) -> Void,
        onCancel: (() -> Void)? = nil,
        onUseDemoProfile: (() -> Void)? = nil
    ) {
        _model = State(initialValue: SurveyModel(mode: mode, draft: draft))
        self.onFinish = onFinish
        self.onCancel = onCancel
        self.onUseDemoProfile = onUseDemoProfile
    }

    var body: some View {
        NavigationStack(path: $model.path) {
            SurveyPageScreen(page: .origin, model: model)
                .toolbar {
                    if let onCancel {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Cancel", action: onCancel)
                        }
                    } else if let onUseDemoProfile {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Use demo profile", action: onUseDemoProfile)
                        }
                    }
                }
                .navigationDestination(for: SurveyPage.self) { page in
                    SurveyPageScreen(page: page, model: model)
                }
        }
        .tint(Theme.tint)
        .interactiveDismissDisabled()
        .sensoryFeedback(.success, trigger: model.isFinished)
        .onChange(of: model.isFinished) { _, finished in
            if finished { onFinish(model.profile) }
        }
        #if DEBUG
        .task { await OnboardingDebugOptions.drive(model) }
        #endif
    }
}

/// One page: the form, its large title with "n of 7", Skip, and Continue.
private struct SurveyPageScreen: View {
    let page: SurveyPage
    @Bindable var model: SurveyModel
    /// The page is showing search suggestions; Continue steps aside.
    @State private var hidesContinue = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        SurveyPageForm(page: page, draft: $model.draft)
            .navigationTitle(page.title(for: dynamicTypeSize))
            .navigationSubtitle(page.progress)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Skip") { model.skip(page) }
                        .accessibilityHint("Leaves this question unanswered")
                }
            }
            .onPreferenceChange(SurveyHidesContinueKey.self) { hidesContinue = $0 }
            .safeAreaInset(edge: .bottom) {
                if !hidesContinue {
                    SurveyContinueButton(title: page.isLast ? "Done" : "Continue") { model.answer(page) }
                        .disabled(model.isFinished)
                }
            }
    }
}

#Preview("Survey") {
    SurveyFlowView(mode: .firstLaunch, draft: .firstLaunch()) { _ in }
        .environment(AppSituationStore.preview(nil))
}
