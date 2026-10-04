#if DEBUG
import Foundation

/// DEBUG `-RyokoDemo nara`: the API for recording the demo video in Nara. It
/// wraps the real API and answers a few requests from a hand-written script,
/// so every take shows the same picks, cards and Mimo reply:
///
/// - Mimo picks: real places around Higashimuki and Nara Park (MapKit finds them).
/// - Place cards for the 7-Eleven and Nara Park (written by the live model for
///   the demo profile, then pinned; the coffee phrase uses the profile's iced coffee).
/// - Mimo: a three-hour walking plan, streamed like the real thing.
///
/// Trip events are dropped. Everything else goes to the wrapped API. Names are
/// typed by hand.
nonisolated struct DemoScriptAPI: RyokoAPI {
    let base: any RyokoAPI

    /// The API for this launch: `base`, or the demo script around it.
    static func wrapping(_ base: any RyokoAPI) -> any RyokoAPI {
        UserDefaults.standard.string(forKey: "RyokoDemo") == "nara" ? DemoScriptAPI(base: base) : base
    }

    func placeCard(_ request: PlaceCardRequest) async throws -> PlaceCardResponse {
        guard let place = request.situation.place, let card = Self.card(for: place) else {
            return try await base.placeCard(request)
        }
        try await Task.sleep(for: .seconds(1.6))
        return card
    }

    func discover(_ request: DiscoverRequest) async throws -> DiscoverResponse {
        try await Task.sleep(for: .seconds(1.8))
        return DiscoverResponse(places: Self.picks)
    }

    func allergyCard(_ request: AllergyCardRequest) async throws -> AllergyCardResponse {
        try await base.allergyCard(request)
    }

    func translate(_ request: TranslateRequest) async throws -> TranslateResponse {
        try await base.translate(request)
    }

    func sonioxKey() async throws -> SonioxKeyResponse {
        try await base.sonioxKey()
    }

    /// Nothing reaches trip memory, so every take starts from the same Mimo.
    func tripEvents(_ request: TripEventsRequest) async throws -> TripEventsResponse {
        TripEventsResponse(stored: 0)
    }

    func mimoMessages(sessionId: String, request: MimoMessageRequest) -> AsyncThrowingStream<MimoEvent, any Error> {
        let message = request.message.lowercased()
        guard message.contains("tour") || message.contains("plan") else {
            return base.mimoMessages(sessionId: sessionId, request: request)
        }
        let events = Self.tourPlan
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Task.sleep(for: .milliseconds(500))
                    continuation.yield(.start(sessionId: sessionId, runId: "run_demo"))
                    for event in events {
                        let pause: Duration = switch event {
                        case .toolStart: .milliseconds(1400)
                        case .toolEnd: .milliseconds(300)
                        default: .milliseconds(120)
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

    // MARK: - Script

    static let picks: [DiscoverPlace] = [
        DiscoverPlace(name: "Nara Park", localName: "奈良公園", why: "Wild deer that bow for a cracker, ¥200 a stack", category: .park, bestTime: "Mornings"),
        DiscoverPlace(name: "Kofuku-ji", localName: "興福寺", why: "Five-storey pagoda, calm before the tour buses", category: .templeShrine, bestTime: "Mornings"),
        DiscoverPlace(name: "Coffee Kan Nara Sanjo", localName: "珈琲館 奈良三条店", why: "Charcoal-roasted coffee in an old-school kissaten", category: .cafe, bestTime: "Mornings"),
        DiscoverPlace(name: "7-Eleven", localName: "セブン-イレブン", why: "Onigiri and iced coffee for the walk, under ¥500", category: .convenienceStore, bestTime: "Anytime"),
        DiscoverPlace(name: "Nakatanidou", localName: "中谷堂", why: "Mochi pounded at lightning speed, warm from the stall", category: .other, bestTime: "Late morning"),
        DiscoverPlace(name: "Higashimuki Shopping Street", localName: "東向商店街", why: "Covered arcade of snacks and souvenirs", category: .shopping, bestTime: "Anytime"),
    ]

    private static func card(for place: Place) -> PlaceCardResponse? {
        let names = [place.name, place.localName ?? ""].map { $0.lowercased() }
        let json: String
        if place.category == .convenienceStore || names.contains(where: { $0.contains("7-eleven") || $0.contains("seven") || $0.contains("セブン") }) {
            json = sevenElevenCard
        } else if names.contains(where: { $0 == "nara park" || $0.contains("奈良公園") }) {
            json = naraParkCard
        } else {
            return nil
        }
        guard var card = try? JSONDecoder().decode(PlaceCardResponse.self, from: Data(json.utf8)) else { return nil }
        card.generatedAt = ISO8601DateFormatter().string(from: .now)
        return card
    }

    private static let sevenElevenCard = #"""
    {
      "language": "ja",
      "phrases": [
        { "id": "pc-demo-711-1", "lang": "ja", "local": "おにぎりを二つください", "romanization": "Onigiri o futatsu kudasai",
          "gloss": "Two rice balls, please", "because": "Quick breakfast before the temples open", "basis": ["place", "localTime"] },
        { "id": "pc-demo-711-2", "lang": "ja", "local": "アイスコーヒーのMサイズをください", "romanization": "Aisu kōhī no emu saizu o kudasai",
          "gloss": "A medium iced coffee, please", "because": "Your usual is an iced coffee", "basis": ["favourites"] },
        { "id": "pc-demo-711-3", "lang": "ja", "local": "ピーナッツアレルギーがあります。このおにぎりにピーナッツは入っていますか",
          "romanization": "Pīnattsu arerugī ga arimasu. Kono onigiri ni pīnattsu wa haitte imasu ka",
          "gloss": "I have a peanut allergy. Does this rice ball contain peanuts?", "because": "Staff can check the label for peanuts", "basis": ["allergy"] }
      ],
      "tips": [
        { "text": "Pay at the counter when you leave, cash or IC card. No tipping here, unlike back home in Canada.", "basis": ["place", "nationality"] },
        { "text": "Mornings are quiet, so the onigiri shelves are still full and you can take your time.", "basis": ["place", "localTime"] }
      ],
      "placeNameLocal": "セブン-イレブン 奈良東向北町店",
      "generatedAt": "2026-10-10T00:40:00Z"
    }
    """#

    private static let naraParkCard = #"""
    {
      "language": "ja",
      "phrases": [
        { "id": "pc-demo-park-1", "lang": "ja", "local": "鹿せんべいはどこで買えますか。", "romanization": "Shika senbei wa doko de kaemasu ka.",
          "gloss": "Where can I buy deer crackers?", "because": "Cracker stalls line the paths all morning", "basis": ["place", "localTime"] },
        { "id": "pc-demo-park-2", "lang": "ja", "local": "東大寺へはどちらですか。", "romanization": "Tōdaiji e wa dochira desu ka.",
          "gloss": "Which way is Todai-ji?", "because": "The temple is a short walk from here", "basis": ["place"] },
        { "id": "pc-demo-park-3", "lang": "ja", "local": "静かに見られる場所はありますか。", "romanization": "Shizuka ni mirareru basho wa arimasu ka.",
          "gloss": "Is there somewhere quiet for viewing?", "because": "You like quiet places over crowds", "basis": ["personality", "place"] }
      ],
      "tips": [
        { "text": "The deer bow before taking a cracker. Bow back, hold it up, break off pieces, and show empty hands when you finish.", "basis": ["place"] },
        { "text": "Deer crackers cost about ¥200 from the stalls and it's cash only. Keep other food and paper maps out of reach: the deer will try.", "basis": ["place"] }
      ],
      "placeNameLocal": "奈良公園",
      "generatedAt": "2026-10-10T00:40:00Z"
    }
    """#

    static let tourPlan: [MimoEvent] = [
        .toolStart(id: "call_search_1", name: .webSearch, label: "Searching the web…"),
        .toolEnd(MimoToolEnd(id: "call_search_1", name: .webSearch, ok: true, details: .webSearch(WebSearchDetails(sources: [
            WebSource(title: "Visit Nara, the official travel guide", url: "https://www.visitnara.jp/"),
            WebSource(title: "Todaiji Temple", url: "https://www.todaiji.or.jp/en/"),
        ])))),
        .text(delta: "Here's an easy three hours on foot,"),
        .text(delta: " all within a short walk of you."),
        .text(delta: " Go early: the deer and the temples are calmest before eleven.\n\n"),
        .toolStart(id: "call_plan_1", name: .showPlaces, label: "Finding places…"),
        .toolEnd(MimoToolEnd(id: "call_plan_1", name: .showPlaces, ok: true, details: .showPlaces(ShowPlacesDetails(places: [
            ShownPlace(name: "Kofuku-ji", localName: "興福寺", why: "The five-storey pagoda, five minutes up the hill", order: 1, when: "09:50"),
            ShownPlace(name: "Nara Park", localName: "奈良公園", why: "Deer crackers at the stalls, ¥200, cash only", order: 2, when: "10:20"),
            ShownPlace(name: "Todai-ji", localName: "東大寺", why: "The Great Buddha hall before the tour buses", order: 3, when: "11:00"),
            ShownPlace(name: "Nakatanidou", localName: "中谷堂", why: "Warm mochi to finish, pounded at lightning speed", order: 4, when: "12:15"),
        ])))),
        .text(delta: "\n\nTodai-ji's Great Buddha hall has a small entry fee,"),
        .text(delta: " paid at the gate:\n\n"),
        .phrase(Phrase(
            id: "mimo-run_demo-1",
            lang: "ja",
            local: "大人一枚お願いします。",
            romanization: "Otona ichi-mai onegaishimasu.",
            gloss: "One adult ticket, please."
        )),
        .done(stopReason: .stop),
    ]
}
#endif
