#if DEBUG
import Foundation
import os

/// DEBUG launch arguments for the Mimo tab, so its states can be driven from
/// the command line (there's no tap automation):
///
///     xcrun simctl launch <udid> com.danielou.ryoko \
///       -RyokoInitialTab mimo -RyokoAPIMode live \
///       -RyokoAgentBaseURLOverride http://127.0.0.1:8794 \
///       -RyokoMimoPreview shanghai -RyokoMimoNewChat 1 -RyokoMimoStarter 0
///
/// - `-RyokoMimoPreview tokyo|shanghai`: preview the sample Tokyo ramen shop at
///   20:00, or a Shanghai café (the fixtures' Wutong Coffee) at 15:00.
/// - `-RyokoMimoNewChat 1`: start with a new chat.
/// - `-RyokoMimoDebugSession <id>`: use this session id (to provoke 409 `session_busy`).
/// - `-RyokoMimoSubject 1`: start a new chat about the preview place, as Ask
///   Mimo does (its first message shows the place's preview).
/// - `-RyokoMimoStarter <n>`: send the n-th starter once nearby places are in.
/// - `-RyokoMimoSend <text>`: send this text instead.
/// - `-RyokoMimoDraft <text>`: put this text in the composer without sending.
/// - `-RyokoMimoFocus 1`: focus the composer (keyboard up).
/// - `-RyokoMimoHistory 1`: open the history sidebar.
/// - `-RyokoMimoScrollTo places`: once the reply is done, scroll to its places.
/// - `-RyokoMimoStopAfter <seconds>`: tap Stop that long after sending.
/// - `-RyokoMimoScript plan|error`: answer from a scripted stream: a plan with
///   web sources (the faux server always replays the same transcript), or a
///   reply that ends in an `error` event followed by text that must be ignored.
/// - `-RyokoMimoTap phrase|place|map`: once the last reply is done and its places
///   are found, tap the first phrase block, the first place chip or Show on map.
///   The router hand-off is logged (category `mimo`).
enum MimoDebug {
    struct Actions {
        var situationStore: AppSituationStore
        var router: AppRouter
        var chat: MimoChat
        var hasNearby: () -> Bool
        var send: (String) -> Void
        var setDraft: (String) -> Void
        var focusComposer: () -> Void
        var openHistory: () -> Void
        var scrollTo: (String) -> Void
        var starters: () -> [String]
        var openShow: (Phrase) -> Void
        var openOnMap: (MimoFoundPlace) -> Void
        var showOnMap: (MimoPlaces) -> Void
    }

    private static var defaults: UserDefaults { .standard }
    /// The hooks run once per launch, not every time the tab appears.
    private static var didRun = false

    /// A scripted API for `-RyokoMimoScript plan`, or nil.
    static var scriptedAPI: (any RyokoAPI)? {
        switch defaults.string(forKey: "RyokoMimoScript") {
        case "plan": MimoScriptedAPI(script: .plan)
        case "error": MimoScriptedAPI(script: .error)
        default: nil
        }
    }

    static func run(on actions: Actions) async {
        guard !didRun else { return }
        didRun = true
        let log = RyokoLog.mimo

        switch defaults.string(forKey: "RyokoMimoPreview") {
        case "tokyo":
            actions.situationStore.previewSample(hour: 20)
        case "shanghai":
            let shanghai = TimeZone(identifier: "Asia/Shanghai")!
            actions.situationStore.startPreview(shanghaiCafe(at: SamplePlaces.next(hour: 15, in: shanghai)))
        default:
            break
        }
        if defaults.bool(forKey: "RyokoMimoNewChat") {
            actions.chat.newChat()
        }
        if let sessionId = defaults.string(forKey: "RyokoMimoDebugSession"), !sessionId.isEmpty {
            actions.chat.debugUseSession(sessionId)
        }
        if defaults.bool(forKey: "RyokoMimoSubject"), let place = actions.situationStore.situation?.place {
            actions.chat.newChat(about: place)
        }

        if let draft = defaults.string(forKey: "RyokoMimoDraft") {
            actions.setDraft(draft)
        }
        if defaults.bool(forKey: "RyokoMimoFocus") {
            try? await Task.sleep(for: .seconds(1))
            actions.focusComposer()
        }
        if defaults.bool(forKey: "RyokoMimoHistory") {
            actions.openHistory()
        }

        // Send once there's a situation and (for up to 4 s) nearby places.
        var message = defaults.string(forKey: "RyokoMimoSend")
        if message == nil, defaults.object(forKey: "RyokoMimoStarter") != nil {
            let starters = actions.starters()
            let index = defaults.integer(forKey: "RyokoMimoStarter")
            message = starters.indices.contains(index) ? starters[index] : starters.first
        }
        if let message {
            for _ in 0..<100 where actions.situationStore.currentSituation() == nil {
                try? await Task.sleep(for: .milliseconds(100))
            }
            for _ in 0..<40 where !actions.hasNearby() {
                try? await Task.sleep(for: .milliseconds(100))
            }
            log.info("DEBUG: sending \(message, privacy: .public) (nearby ready: \(actions.hasNearby()))")
            actions.send(message)
            if defaults.object(forKey: "RyokoMimoStopAfter") != nil {
                try? await Task.sleep(for: .seconds(defaults.double(forKey: "RyokoMimoStopAfter")))
                log.info("DEBUG: tapping Stop")
                actions.chat.stop()
            }
        }

        let tap = defaults.string(forKey: "RyokoMimoTap")
        let scrollTarget = defaults.string(forKey: "RyokoMimoScrollTo")
        guard tap != nil || scrollTarget != nil else { return }
        // Wait up to 30 s for the last reply to end and its places to be found.
        var turn: MimoTurn?
        for _ in 0..<300 {
            if let last = actions.chat.turns.last, !last.isStreaming, last.placesFound {
                turn = last
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let turn else {
            log.error("DEBUG: no finished reply to tap")
            return
        }
        try? await Task.sleep(for: .seconds(1.5))
        if scrollTarget == "places",
           let index = turn.segments.firstIndex(where: { $0.places != nil }) {
            actions.scrollTo(MimoTurnView.segmentID(turn: turn.id, index: index))
        }
        guard let tap else { return }
        switch tap {
        case "phrase":
            if let phrase = turn.segments.lazy.compactMap(\.phrase).first { actions.openShow(phrase) }
        case "place":
            if let place = turn.segments.lazy.compactMap(\.places).first?.found?.first { actions.openOnMap(place) }
        case "map":
            if let places = turn.segments.lazy.compactMap(\.places).first { actions.showOnMap(places) }
        default:
            log.error("DEBUG: unknown -RyokoMimoTap \(tap, privacy: .public)")
            return
        }
        let router = actions.router
        log.info(
            "DEBUG router after tap \(tap, privacy: .public): tab=\(router.selectedTab.rawValue, privacy: .public) show=\(router.show?.id ?? "nil", privacy: .public) fromMimo=\(router.fromMimo.count) mapFocus=\(String(describing: router.mapFocus), privacy: .public)"
        )
    }

    /// The Shanghai café from the fixtures (`situation.shanghai-cafe.json`),
    /// typed by hand.
    static func shanghaiCafe(at date: Date) -> SituationPreview {
        SituationPreview(
            place: Place(
                id: nil,
                name: "Wutong Coffee",
                localName: "梧桐咖啡",
                category: .cafe,
                address: "118 Yuyuan Road, Jing'an District, Shanghai",
                coordinate: Coordinate(lat: 31.2238, lon: 121.4412)
            ),
            date: date,
            timeZone: TimeZone(identifier: "Asia/Shanghai")!,
            city: "Shanghai",
            district: "Jing'an",
            countryCode: "CN"
        )
    }
}

extension MimoChat {
    /// DEBUG: talk on a given session id, starting empty.
    func debugUseSession(_ sessionId: String) {
        newChat()
        debugReplaceTranscript(MimoTranscript(sessionId: sessionId))
    }
}

private extension MimoTurn {
    /// True when every places segment has been looked up.
    var placesFound: Bool {
        segments.allSatisfy { segment in
            if case let .places(places) = segment { places.found != nil } else { true }
        }
    }
}

private extension MimoSegment {
    var phrase: Phrase? {
        if case let .phrase(phrase) = self { phrase } else { nil }
    }

    var places: MimoPlaces? {
        if case let .places(places) = self { places } else { nil }
    }
}

// MARK: - Scripted stream

/// Answers Mimo messages with a hand-written stream that has a plan (numbered
/// stops with times), a phrase and web sources, in the situation's language.
/// Everything else comes from the fixtures. Names are typed by hand.
nonisolated struct MimoScriptedAPI: RyokoAPI {
    enum Script: Sendable {
        case plan
        case error
    }

    var script: Script
    private let fixtures = FixtureRyokoAPI()

    func placeCard(_ request: PlaceCardRequest) async throws -> PlaceCardResponse {
        try await fixtures.placeCard(request)
    }

    func discover(_ request: DiscoverRequest) async throws -> DiscoverResponse {
        try await fixtures.discover(request)
    }

    func allergyCard(_ request: AllergyCardRequest) async throws -> AllergyCardResponse {
        try await fixtures.allergyCard(request)
    }

    func mimoMessages(sessionId: String, request: MimoMessageRequest) -> AsyncThrowingStream<MimoEvent, any Error> {
        let events = switch script {
        case .plan: request.situation.localLanguage.hasPrefix("zh") ? Self.shanghaiPlan : Self.tokyoPlan
        case .error: Self.endsInError
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Task.sleep(for: .milliseconds(400))
                    continuation.yield(.start(sessionId: sessionId, runId: "run_debug"))
                    for event in events {
                        let pause: Duration = switch event {
                        case .toolStart, .toolEnd: .milliseconds(700)
                        default: .milliseconds(90)
                        }
                        try await Task.sleep(for: pause)
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Text, a failed tool, then an `error` event. The text after it must not show.
    static let endsInError: [MimoEvent] = [
        .text(delta: "Let me look that up for you."),
        .toolStart(id: "call_search_1", name: .webSearch, label: "Searching the web…"),
        .toolEnd(MimoToolEnd(id: "call_search_1", name: .webSearch, ok: false, details: .webSearch(WebSearchDetails(sources: [])))),
        .error(ErrorBody(code: .timeout, message: "Mimo took too long to answer. Try again.", retryable: true)),
        .text(delta: " THIS TEXT ARRIVED AFTER THE ERROR AND MUST NOT SHOW."),
        .done(stopReason: .stop),
    ]

    static let tokyoPlan: [MimoEvent] = [
        .toolStart(id: "call_search_1", name: .webSearch, label: "Searching the web…"),
        .toolEnd(MimoToolEnd(id: "call_search_1", name: .webSearch, ok: true, details: .webSearch(WebSearchDetails(sources: [
            WebSource(title: "Go Tokyo, the official Tokyo travel guide", url: "https://www.gotokyo.org/en/"),
            WebSource(title: "Shinjuku City", url: "https://www.city.shinjuku.lg.jp/"),
        ])))),
        .text(delta: "Here's an easy evening, all on foot."),
        .text(delta: " The alleys get busy after nine, so start with yakitori and keep the bars for later.\n\n"),
        .toolStart(id: "call_plan_1", name: .showPlaces, label: "Finding places…"),
        .toolEnd(MimoToolEnd(id: "call_plan_1", name: .showPlaces, ok: true, details: .showPlaces(ShowPlacesDetails(places: [
            ShownPlace(name: "Omoide Yokocho", localName: "思い出横丁", why: "Tiny yakitori stalls, smoky and local", order: 1, when: "20:30"),
            ShownPlace(name: "Shinjuku Golden Gai", localName: "新宿ゴールデン街", why: "Six lanes of small bars, some seat five", order: 2, when: "21:30"),
            ShownPlace(name: "Tsubakiya Coffee Shinjuku", localName: "椿屋珈琲 新宿本館", why: "A slow coffee to end the night", order: 3, when: "22:45"),
        ])))),
        .text(delta: "\n\nSome Golden Gai bars charge a seat fee, so ask at the door:\n\n"),
        .phrase(Phrase(
            id: "mimo-run_debug-1",
            lang: "ja",
            local: "席料はかかりますか？",
            romanization: "Sekiryō wa kakarimasu ka?",
            gloss: "Is there a seat charge?"
        )),
        .done(stopReason: .stop),
    ]

    static let shanghaiPlan: [MimoEvent] = [
        .toolStart(id: "call_search_1", name: .webSearch, label: "Searching the web…"),
        .toolEnd(MimoToolEnd(id: "call_search_1", name: .webSearch, ok: true, details: .webSearch(WebSearchDetails(sources: [
            WebSource(title: "Meet in Shanghai, the city's travel guide", url: "https://www.meet-in-shanghai.net/"),
        ])))),
        .text(delta: "Here's a quiet afternoon in Jing'an, all within a short walk."),
        .text(delta: " The temple is calmest before four.\n\n"),
        .toolStart(id: "call_plan_1", name: .showPlaces, label: "Finding places…"),
        .toolEnd(MimoToolEnd(id: "call_plan_1", name: .showPlaces, ok: true, details: .showPlaces(ShowPlacesDetails(places: [
            ShownPlace(name: "Jing'an Temple", localName: "静安寺", why: "Golden roofs, quiet in the side halls", order: 1, when: "15:30"),
            ShownPlace(name: "Zhang Yuan", localName: "张园", why: "Restored stone-gate lanes to wander", order: 2, when: "16:30"),
            ShownPlace(name: "Jing'an Sculpture Park", localName: "静安雕塑公园", why: "Lawns and sculptures as the light softens", order: 3, when: "17:30"),
        ])))),
        .text(delta: "\n\nThe temple charges a small entry fee at the gate:\n\n"),
        .phrase(Phrase(
            id: "mimo-run_debug-1",
            lang: "zh-Hans",
            local: "一张门票，谢谢。",
            romanization: "Yì zhāng ménpiào, xièxie.",
            gloss: "One ticket, please."
        )),
        .done(stopReason: .stop),
    ]
}
#endif
