import Observation
import SwiftUI
import os

/// Opens the allergy card in Show mode from a button: Nearby's quick card and
/// Me's preview row. Template-only cards open at once; a card with free-text
/// allergens waits for the server (or its saved answer) and shows `isLoading`.
///
/// If the free-text lines can't be fetched, `failure` is set and
/// `.allergyCardFailureAlert(_:)` offers Try again or Show without it, so a
/// missing allergen is never silently dropped.
@MainActor
@Observable
final class AllergyCardPresenter {
    private(set) var isLoading = false
    var failure: AllergyCardStore.FreeTextFailure?

    @ObservationIgnored private var lastRequest: Request?
    @ObservationIgnored private var task: Task<Void, Never>?

    private struct Request {
        var profile: Profile
        var language: String
        var api: any RyokoAPI
        var router: AppRouter
    }

    func present(profile: Profile, language: String, api: any RyokoAPI, router: AppRouter) {
        let request = Request(profile: profile, language: language, api: api, router: router)
        lastRequest = request
        run(request)
    }

    /// The alert's Try again.
    func retry() {
        failure = nil
        if let lastRequest { run(lastRequest) }
    }

    /// The alert's Show without it: the template lines only.
    func showPartial() {
        guard let partial = failure?.partial, let router = lastRequest?.router else { return }
        failure = nil
        router.show = .allergy(partial)
    }

    private func run(_ request: Request) {
        task?.cancel()
        isLoading = true
        task = Task { [weak self] in
            do {
                let card = try await AllergyCardStore.shared.card(
                    profile: request.profile, language: request.language, api: request.api
                )
                guard !Task.isCancelled else { return }
                self?.isLoading = false
                request.router.show = .allergy(card)
            } catch let failure as AllergyCardStore.FreeTextFailure {
                self?.isLoading = false
                self?.failure = failure
            } catch is CancellationError {
                // A newer tap took over.
            } catch {
                self?.isLoading = false
                RyokoLog.show.error("Allergy card failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

extension View {
    /// The alert for a free-text allergen that couldn't be written.
    func allergyCardFailureAlert(_ presenter: AllergyCardPresenter) -> some View {
        modifier(AllergyCardFailureAlert(presenter: presenter))
    }
}

private struct AllergyCardFailureAlert: ViewModifier {
    @Bindable var presenter: AllergyCardPresenter

    func body(content: Content) -> some View {
        let isPresented = Binding(
            get: { presenter.failure != nil },
            set: { if !$0 { presenter.failure = nil } }
        )
        content.alert(title, isPresented: isPresented, presenting: presenter.failure) { failure in
            Button("Try again") { presenter.retry() }
            if failure.partial != nil {
                Button("Show without it") { presenter.showPartial() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { failure in
            Text("\(failure.message) Your card can't include \(Self.list(failure.labels)) until it's written.")
        }
    }

    private var title: String {
        guard let labels = presenter.failure?.labels, !labels.isEmpty else { return "Can't finish the allergy card" }
        return "Can't add \(Self.list(labels))"
    }

    private static func list(_ labels: [String]) -> String {
        labels.formatted(.list(type: .and))
    }
}
