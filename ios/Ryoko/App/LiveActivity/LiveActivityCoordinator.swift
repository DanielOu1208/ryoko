import ActivityKit
import Foundation
import Observation
import UIKit
import os

/// Runs the Live Activity for the active place (design §4.11). `RyokoApp`
/// starts it once with the stores, and hands it `ryoko://` links.
///
/// - **Starts** when the active situation has a place: a place confirmed live,
///   or a preview. Not for city-only, and not where you speak the local
///   language (place cards show no phrases there either). ActivityKit only starts
///   activities from the foreground, so a start that comes in the background
///   waits until the app is active again.
/// - **One at a time.** Every activity from an earlier launch ends at start,
///   and the current one ends when the place changes.
/// - **Content:** a placeholder first, then the place card's top phrase. The
///   card comes from the shared `RyokoAPI`; the server caches it, so this costs
///   nothing extra when the Map's place card asks for the same card. It reloads when the
///   situation (a new hour, a new preview time), the profile or the API changes.
///   Profile edits wait until they settle (`profileSettleDelay`): every profile
///   version is a new server generation (design §7.4), so a burst of edits in
///   Me loads once.
/// - **Ends** when the situation has no place (or is gone), on a new place, or
///   after two hours, which is also its `staleDate`.
/// - **Deep link:** a tap opens the Map with the current place's card. Each
///   phrase it shows is kept (`LiveActivityPhraseStore`), so
///   `ryoko://show?phrase=<id>` also opens Show mode for it, on a cold start too.
@MainActor
final class LiveActivityCoordinator {
    typealias RyokoActivity = Activity<RyokoActivityAttributes>
    typealias ContentState = RyokoActivityAttributes.ContentState

    /// How long an activity runs (design §4.11). The system allows 8 hours.
    static var lifetime: TimeInterval {
        #if DEBUG
        if let seconds = LiveActivityDebugOptions.lifetimeOverride { return seconds }
        #endif
        return 2 * 60 * 60
    }

    /// How long a change to the profile alone waits before the activity
    /// follows it. Situation and API changes are followed at once.
    static let profileSettleDelay: Duration = .seconds(2.5)

    let phrases = LiveActivityPhraseStore()

    /// What the activity follows. Equal inputs never reload anything.
    struct Inputs: Equatable, Sendable {
        var situation: Situation?
        var profile: Profile
        var apiGeneration: Int
    }

    /// Which place an activity is for. A new key is a new activity; the same
    /// key (a new hour, a new preview time) updates the one running.
    struct PlaceKey: Hashable {
        var mode: SituationMode
        var place: String
    }

    /// The running activity. Only its id is kept: `Activity` isn't `Sendable`,
    /// so each update looks up a fresh instance (`activity(id:)`).
    private struct Running {
        let activityID: String
        let attributes: RyokoActivityAttributes
        let key: PlaceKey
        let startedAt: Date
        var state: ContentState
        /// The inputs the content was last loaded for, and whether that failed.
        var loadedFor: Inputs?
        var loadFailed = false

        var staleDate: Date { startedAt.addingTimeInterval(LiveActivityCoordinator.lifetime) }
    }

    private var apiStore: APIStore?
    private var latest: Inputs?
    private var running: Running?
    /// A place whose two hours ran out: no new activity until the place changes.
    private var expiredKey: PlaceKey?
    /// The inputs a place-card load is in flight for.
    private var loadingFor: Inputs?

    private var observeTask: Task<Void, Never>?
    private var activeTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    /// A reconcile waiting for profile edits to settle.
    private var settleTask: Task<Void, Never>?
    /// The last content update sent; the next one waits for it.
    private var pushTask: Task<Void, Never>?

    init() {}

    // MARK: Start

    /// Ends activities left from an earlier launch, then follows the stores.
    /// Safe to call more than once; only the first call does anything.
    func start(situationStore: AppSituationStore, profileStore: ProfileStore, apiStore: APIStore) {
        guard observeTask == nil else { return }
        self.apiStore = apiStore
        endAll(reason: "launch")

        observeTask = Task { [weak self] in
            let inputs = Observations {
                Inputs(
                    situation: situationStore.situation,
                    profile: profileStore.profile,
                    apiGeneration: apiStore.apiGeneration
                )
            }
            for await value in inputs {
                self?.receive(value)
            }
        }
        // A start that came while in the background, a failed load, or the end
        // of the two hours: all are checked again whenever the app is active.
        activeTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) {
                self?.appBecameActive()
            }
        }
    }

    // MARK: Deep link

    /// Handles a `ryoko://` link. Every link opens the Map with the current
    /// place's card; a phrase link also opens Show mode for that kept phrase
    /// on top, so Done lands on the place's card. Returns false for a link
    /// that isn't Ryoko's.
    @discardableResult
    func open(_ url: URL, router: AppRouter) -> Bool {
        guard let link = RyokoDeepLink(url: url) else {
            RyokoLog.liveActivity.error("Unknown link \(url.absoluteString, privacy: .public)")
            return false
        }
        router.openMapAtCurrentPlace()
        switch link {
        case let .show(phraseID):
            if let phrase = phrases.phrase(id: phraseID) {
                RyokoLog.liveActivity.info("Link opens Show mode for \(phraseID, privacy: .public)")
                router.show = .phrase(phrase)
            } else {
                // Not kept (an old link): the place's card has its phrases.
                RyokoLog.liveActivity.error("Link names an unknown phrase \(phraseID, privacy: .public); opening the place's card")
            }
        case .currentPlace:
            RyokoLog.liveActivity.info("Link opens the current place's card")
        }
        return true
    }

    // MARK: Following the situation

    private func receive(_ inputs: Inputs) {
        guard inputs != latest else { return }
        let profileOnly = latest.map {
            $0.situation == inputs.situation && $0.apiGeneration == inputs.apiGeneration
        } ?? false
        latest = inputs
        settleTask?.cancel()
        settleTask = nil
        guard profileOnly else {
            reconcile()
            return
        }
        // Each new edit restarts the wait; the reconcile uses the latest inputs.
        settleTask = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.profileSettleDelay)
            } catch {
                return // a newer input came first
            }
            guard !Task.isCancelled else { return }
            self?.settleTask = nil
            self?.reconcile()
        }
    }

    private func appBecameActive() {
        if let running, Date.now >= running.staleDate {
            expire(running.activityID)
            return
        }
        reconcile()
    }

    /// Brings the activity in line with the latest inputs.
    private func reconcile() {
        guard let inputs = latest else { return }
        guard let target = Target(inputs) else {
            expiredKey = nil
            if running != nil { endAll(reason: "no place") }
            return
        }
        if expiredKey != target.key { expiredKey = nil }

        if var current = running, current.key == target.key {
            // Same place: a new hour, a new preview time, or a new profile.
            if current.state.previewDate != target.previewDate {
                current.state.previewDate = target.previewDate
                running = current
                push()
            }
            let needsLoad = current.loadedFor != inputs || current.loadFailed
            if needsLoad, loadingFor != inputs { load(for: inputs) }
            return
        }

        if running != nil || !RyokoActivity.activities.isEmpty { endAll(reason: "new place") }
        guard expiredKey == nil else { return }
        begin(target, inputs: inputs)
    }

    private func begin(_ target: Target, inputs: Inputs) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            RyokoLog.liveActivity.info("Live Activities are off for Ryoko")
            return
        }
        guard UIApplication.shared.applicationState != .background else {
            // ActivityKit starts activities from the foreground only.
            RyokoLog.liveActivity.info("Waiting for the foreground to start")
            return
        }
        let state = ContentState.placeholder(previewDate: target.previewDate)
        let startedAt = Date.now
        do {
            let activity = try RyokoActivity.request(
                attributes: target.attributes,
                content: ActivityContent(state: state, staleDate: startedAt.addingTimeInterval(Self.lifetime)),
                pushType: nil
            )
            running = Running(
                activityID: activity.id,
                attributes: target.attributes,
                key: target.key,
                startedAt: startedAt,
                state: state
            )
            RyokoLog.liveActivity.info(
                "Started \(activity.id, privacy: .public) for \(target.attributes.placeName, privacy: .public) (\(target.key.mode.rawValue, privacy: .public)), \(ActivityText.payloadSize(target.attributes, state)) bytes"
            )
            scheduleExpiry(activity.id, at: startedAt.addingTimeInterval(Self.lifetime))
            load(for: inputs)
        } catch {
            RyokoLog.liveActivity.error("Couldn't start: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Content

    /// Loads the place card and puts its top phrase on the running activity.
    private func load(for inputs: Inputs) {
        guard let apiStore, let current = running, let situation = inputs.situation else { return }
        loadTask?.cancel()
        loadingFor = inputs
        let activityID = current.activityID
        let api = apiStore.api
        // The situation is only as fresh as its hour: send the actual local time.
        let request = PlaceCardRequest(profile: inputs.profile, situation: situation.stamped())
        loadTask = Task { [weak self] in
            let result: Result<PlaceCardResponse, any Error>
            do {
                result = .success(try await api.placeCard(request))
            } catch is CancellationError {
                return
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled else { return }
            self?.finishLoad(result, for: inputs, activityID: activityID)
        }
    }

    private func finishLoad(_ result: Result<PlaceCardResponse, any Error>, for inputs: Inputs, activityID: String) {
        if loadingFor == inputs { loadingFor = nil }
        guard var current = running, current.activityID == activityID else { return }
        current.loadedFor = inputs
        current.state.isLoading = false
        switch result {
        case let .success(card):
            current.loadFailed = false
            if let top = card.phrases.first {
                // Keep it before it shows, so a tap can always find it.
                phrases.keep(top)
                current.state.phrase = ActivityPhrase(top)
            } else {
                current.state.phrase = nil
            }
        case let .failure(error):
            // Keep the phrase already shown, if any; try again when the app is next active.
            current.loadFailed = true
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            RyokoLog.liveActivity.error("Place card failed: \(message, privacy: .public)")
        }
        running = current
        push()
    }

    /// Sends the running activity's content to the system. Pushes run one after
    /// another and each sends the state as it is when it runs, so the last
    /// content to arrive is always the latest.
    private func push() {
        let previous = pushTask
        pushTask = Task { [weak self] in
            await previous?.value
            await self?.pushLatest()
        }
    }

    private func pushLatest() async {
        guard let running, let activity = Self.activity(id: running.activityID) else { return }
        let content = ActivityContent(state: running.state, staleDate: running.staleDate)
        await activity.update(content)
        RyokoLog.liveActivity.info(
            "Updated \(running.activityID, privacy: .public): phrase \(running.state.phrase?.id ?? "none", privacy: .public), \(ActivityText.payloadSize(running.attributes, running.state)) bytes"
        )
    }

    /// A fresh instance, not tied to the main actor, so it can be sent to
    /// ActivityKit's concurrent `update` and `end`.
    nonisolated private static func activity(id: String) -> sending RyokoActivity? {
        RyokoActivity.activities.first { $0.id == id }
    }

    // MARK: Ending

    private func scheduleExpiry(_ activityID: String, at deadline: Date) {
        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(max(1, deadline.timeIntervalSinceNow)))
            } catch {
                return // ended or replaced first
            }
            self?.expire(activityID)
        }
    }

    /// The two hours are up: end it, and don't start another for this place.
    private func expire(_ activityID: String) {
        guard let current = running, current.activityID == activityID else { return }
        expiredKey = current.key
        endAll(reason: "two hours are up")
    }

    /// Ends every Ryoko activity, including any from an earlier launch.
    private func endAll(reason: String) {
        loadTask?.cancel()
        loadTask = nil
        loadingFor = nil
        expiryTask?.cancel()
        expiryTask = nil
        running = nil
        // Only the ones that exist now: a new activity may be requested right after.
        let ids = Set(RyokoActivity.activities.map(\.id))
        guard !ids.isEmpty else { return }
        RyokoLog.liveActivity.info("Ending \(ids.count) activit\(ids.count == 1 ? "y" : "ies") (\(reason, privacy: .public))")
        Task {
            for activity in RyokoActivity.activities where ids.contains(activity.id) {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}

// MARK: - Target

private extension LiveActivityCoordinator {
    /// The activity the inputs call for, or nil for none: no situation, no
    /// place (city-only), or a local language the profile speaks.
    struct Target {
        let key: PlaceKey
        let attributes: RyokoActivityAttributes
        let previewDate: Date?

        init?(_ inputs: Inputs) {
            guard let situation = inputs.situation, let place = situation.place,
                  !inputs.profile.speaks(situation.localLanguage) else { return nil }
            let where_ = place.id ?? "\(place.name)@\(String(format: "%.4f,%.4f", place.coordinate.lat, place.coordinate.lon))"
            key = PlaceKey(mode: situation.mode, place: where_)
            attributes = RyokoActivityAttributes(
                placeName: place.name,
                city: situation.city,
                categorySymbol: place.category.sfSymbol,
                timeZoneID: situation.timeZone,
                isPreview: situation.mode == .preview
            )
            previewDate = situation.mode == .preview ? situation.date : nil
        }
    }
}
