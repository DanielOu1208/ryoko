// Mac-side check of the Swift contract mirrors (ios/Shared/) and the
// Foundation-only parts of ios/Ryoko/App/Core/. Built and run by
// ios/scripts/check-contracts.sh; not part of any Xcode target.

import Foundation

let env = ProcessInfo.processInfo.environment
let root = URL(fileURLWithPath: env["RYOKO_ROOT"] ?? FileManager.default.currentDirectoryPath)
let examples = root.appending(path: "contracts/examples")
let tables = root.appending(path: "contracts/tables")
let bundled = root.appending(path: "ios/Ryoko/App/Core/Fixtures")

var failures = 0
var passes = 0

func expect(_ condition: @autoclosure () throws -> Bool, _ label: String) {
    do {
        if try condition() {
            passes += 1
        } else {
            failures += 1
            print("  FAIL \(label)")
        }
    } catch {
        failures += 1
        print("  FAIL \(label): \(error)")
    }
}

func section(_ title: String) { print("\n== \(title)") }

func json(_ value: some Encodable) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
}

// MARK: - Fixture round trips

for (label, directory) in [("contracts/examples", examples), ("Core/Fixtures (bundled copies)", bundled)] {
    section("Round trip every fixture in \(label)")
    for outcome in FixtureSelfCheck.run(source: .directory(directory)) {
        if let failure = outcome.failure {
            failures += 1
            print("  FAIL \(outcome.file.fileName): \(failure)")
        } else {
            passes += 1
            print("  pass \(outcome.file.fileName)")
        }
    }
}

// MARK: - Required-nullable keys are written as null

section("Explicit nulls and omitted optionals")
do {
    let skipped = Profile(
        version: String(repeating: "0", count: 64), nationality: nil, homeLanguage: "en",
        spokenLanguages: nil, diet: nil, dietNotes: nil, allergies: nil, favourites: nil,
        taste: Taste(sweetness: nil, spice: 3), personality: Personality(rhythm: nil, food: .myUsual, budget: nil, vibe: nil),
        homeBase: nil
    )
    let object = try json(skipped)
    let nullKeys = ["nationality", "spokenLanguages", "diet", "dietNotes", "allergies", "favourites", "homeBase"]
    expect(nullKeys.allSatisfy { object[$0] is NSNull }, "profile writes skipped fields as null")
    expect((object["taste"] as? [String: Any])?["sweetness"] is NSNull, "taste writes a skipped slider as null")
    expect((object["personality"] as? [String: Any])?["rhythm"] is NSNull, "personality writes a skipped pair as null")

    let latin = Phrase(id: "p", lang: "en", local: "Hi", romanization: nil, gloss: "Hi")
    let phrase = try json(latin)
    expect(phrase["romanization"] is NSNull, "phrase writes romanization: null")
    expect(phrase["because"] == nil && phrase["basis"] == nil, "phrase omits because and basis when nil")

    var cityOnly = try FixtureSource.directory(examples).decode(Situation.self, from: .situationShanghai)
    cityOnly.place = nil
    cityOnly.district = nil
    let situation = try json(cityOnly)
    expect(situation["place"] is NSNull, "situation writes place: null in city-only mode")
    expect(situation["district"] == nil, "situation omits district when nil")

    let chip = try json(Allergy(id: .peanut, label: nil, severity: .serious))
    expect(chip.keys.sorted() == ["id", "severity"], "chip allergy has no label key")
} catch {
    failures += 1
    print("  FAIL building values: \(error)")
}

// MARK: - SSE line reader

section("SSE line reader")
expect(SSELineReader.parse(": ping") == .ignored, "comment is ignored")
expect(SSELineReader.parse("") == .ignored, "blank line is ignored")
expect(SSELineReader.parse("event: text") == .ignored, "event field is ignored")
expect(SSELineReader.parse("retry: 1000") == .ignored, "retry field is ignored")
expect(SSELineReader.parse(#"data:{"type":"text","delta":"a"}"#) == .event(.text(delta: "a")), "data without a space")
expect(SSELineReader.parse(#"data: {"type":"text","delta":" b"}"# + "\r") == .event(.text(delta: " b")), "CRLF line, leading space kept in the delta")
expect(SSELineReader.parse(#"data: {"type":"brand_new","x":1}"#) == .event(.unknown(type: "brand_new")), "unknown type decodes as .unknown")
if case .malformed = SSELineReader.parse("data: not json") { passes += 1 } else { failures += 1; print("  FAIL junk data is malformed") }
if case .malformed = SSELineReader.parse(#"data: {"type":"text"}"#) { passes += 1 } else { failures += 1; print("  FAIL text without delta is malformed") }
let webSearchEnd = #"data: {"type":"tool_end","id":"t1","name":"web_search","ok":true,"details":{"sources":[{"title":"A","url":"https://example.com/a"}]}}"#
if case let .event(.toolEnd(end)) = SSELineReader.parse(webSearchEnd), case let .webSearch(details) = end.details {
    expect(details.sources.first?.link?.host() == "example.com", "web_search tool_end decodes sources")
} else {
    failures += 1
    print("  FAIL web_search tool_end")
}
let futureToolEnd = #"data: {"type":"tool_end","id":"t2","name":"book_table","ok":false,"details":{"anything":[1]}}"#
expect(SSELineReader.parse(futureToolEnd) == .event(.toolEnd(MimoToolEnd(id: "t2", name: ToolName(rawValue: "book_table"), ok: false, details: .unknown))), "unknown tool's tool_end still decodes")
let errorEvent = #"data: {"type":"error","code":"timeout","message":"Took too long.","retryable":true}"#
expect(SSELineReader.parse(errorEvent) == .event(.error(ErrorBody(code: .timeout, message: "Took too long.", retryable: true))), "error event")

// The byte reader splits at LF only. Raw NEL, LS and PS inside a JSON string
// (which `AsyncBytes.lines` would split at) stay in their line.
let rawBreaks = "a\u{2028}b\u{2029}c\u{85}d"
let wire = ": " + String(repeating: ".", count: 600) + "\n\n"
    + "data: {\"type\":\"text\",\"delta\":\"\(rawBreaks)\"}\r\n\r\n"
    + "data: {\"type\":\"tool_end\",\"id\":\"t1\",\"name\":\"web_search\",\"ok\":true,\"details\":{\"sources\":[{\"title\":\"Ramen\u{2028}guide\",\"url\":\"https://example.com/a\"}]}}\n\n"
    + ": ping\n\n"
    + "data: {\"type\":\"done\",\"stopReason\":\"stop\"}" // no final LF: the last line still counts
func wireBytes() -> AsyncStream<UInt8> {
    AsyncStream { continuation in
        for byte in Array(wire.utf8) { continuation.yield(byte) }
        continuation.finish()
    }
}
var readerEvents: [MimoEvent] = []
try await SSELineReader.read(bytes: wireBytes()) { readerEvents.append($0) }
expect(readerEvents.count == 3, "byte reader: 3 events from the wire, got \(readerEvents.count)")
expect(readerEvents.first == .text(delta: rawBreaks), "byte reader: raw U+2028, U+2029 and U+0085 stay inside the delta")
if readerEvents.count > 1, case let .toolEnd(end) = readerEvents[1], case let .webSearch(details) = end.details {
    expect(details.sources.first?.title == "Ramen\u{2028}guide", "byte reader: a title with a raw U+2028 survives")
} else {
    failures += 1
    print("  FAIL byte reader: web_search tool_end with a raw U+2028 in its title")
}
expect(readerEvents.last == .done(stopReason: .stop), "byte reader: a last line without LF is read")
var eventsViaLines = 0 // the old way, for contrast
for try await line in wireBytes().lines {
    if case .event = SSELineReader.parse(line) { eventsViaLines += 1 }
}
print("  (AsyncBytes.lines reads \(eventsViaLines) of these 3 events)")

// MARK: - Situation clock

section("Situation clock")
let instant = try! Date("2026-10-05T07:00:00Z", strategy: .iso8601)
let shanghai = Situation.clock(for: instant, in: TimeZone(identifier: "Asia/Shanghai")!)
expect(shanghai.localTime == "2026-10-05T15:00:00+08:00" && shanghai.hourBucket == "2026-10-05T15", "Shanghai \(shanghai)")
let vancouver = Situation.clock(for: instant, in: TimeZone(identifier: "America/Vancouver")!)
expect(vancouver.localTime == "2026-10-05T00:00:00-07:00" && vancouver.hourBucket == "2026-10-05T00", "Vancouver \(vancouver)")
let kolkata = Situation.clock(for: instant, in: TimeZone(identifier: "Asia/Kolkata")!)
expect(kolkata.localTime == "2026-10-05T12:30:00+05:30", "Kolkata half-hour offset \(kolkata)")
let built = Situation(mode: .preview, date: instant, timeZone: TimeZone(identifier: "Asia/Tokyo")!, place: nil, city: "Tokyo", countryCode: "JP", localLanguage: "ja")
expect(built.localTime == "2026-10-05T16:00:00+09:00" && built.date == instant, "Situation(date:) round trips the instant")
let builtLive = Situation(mode: .live, date: instant, timeZone: TimeZone(identifier: "Asia/Kolkata")!, place: nil, city: "Mumbai", countryCode: "IN", localLanguage: "hi")
let later = instant.addingTimeInterval(95 * 60) // 12:30 → 14:05 in Kolkata
let restamped = builtLive.stamped(at: later)
expect(restamped.localTime == "2026-10-05T14:05:00+05:30" && restamped.hourBucket == "2026-10-05T14", "stamped(at:) re-stamps a live situation in its own zone \(restamped.localTime)")
expect(restamped.city == builtLive.city && restamped.mode == .live && restamped.timeZone == builtLive.timeZone, "stamped(at:) keeps everything but the clock")
expect(built.stamped(at: later) == built, "stamped(at:) leaves a preview at its committed time")
let kolkataZone = TimeZone(identifier: "Asia/Kolkata")!
let kolkataNext = Situation.nextHour(after: instant, in: kolkataZone) // 12:30 local
expect(Situation.clock(for: kolkataNext, in: kolkataZone).localTime == "2026-10-05T13:00:00+05:30", "nextHour is the place's hour, not the device's (Kolkata 12:30 → 13:00)")
let tokyoZone = TimeZone(identifier: "Asia/Tokyo")!
let onTheHour = try! Date("2026-10-05T07:00:00Z", strategy: .iso8601) // 16:00 in Tokyo
expect(Situation.nextHour(after: onTheHour, in: tokyoZone) == onTheHour.addingTimeInterval(3600), "nextHour on the hour is the following hour")
// Every 7 minutes over the US fall-back day, in zones with whole, half and quarter hour offsets:
// the next tick is after now, at most an hour away, and at minute 0 in the place's zone.
var tickOK = true
for zoneId in ["America/Vancouver", "Asia/Kolkata", "Asia/Kathmandu", "Asia/Shanghai"] {
    let zone = TimeZone(identifier: zoneId)!
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    for step in 0..<(26 * 60 / 7) {
        let now = try! Date("2026-11-01T00:00:00Z", strategy: .iso8601).addingTimeInterval(Double(step * 7 * 60))
        let next = Situation.nextHour(after: now, in: zone)
        let gap = next.timeIntervalSince(now)
        if !(gap > 0 && gap <= 3600 && calendar.component(.minute, from: next) == 0) {
            tickOK = false
            print("  \(zoneId) \(now) → \(next)")
        }
    }
}
expect(tickOK, "nextHour: after now, within an hour, on the place's hour (whole, half and quarter hour zones, DST)")

// MARK: - Tables match contracts/tables

section("LangCode matches contracts/tables/langcodes.json")
do {
    let data = try Data(contentsOf: tables.appending(path: "langcodes.json"))
    let rows = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["languages"] as? [[String: Any]] ?? []
    expect(rows.count == LangCode.allCases.count, "same number of languages (\(rows.count))")
    for row in rows {
        let tag = row["tag"] as? String ?? "?"
        guard let code = LangCode(rawValue: tag) else {
            failures += 1
            print("  FAIL no LangCode for \(tag)")
            continue
        }
        expect(code.status.rawValue == row["status"] as? String, "\(tag) status")
        expect(code.displayName == row["displayName"] as? String, "\(tag) displayName")
        expect(code.nativeName == row["nativeName"] as? String, "\(tag) nativeName")
        expect(code.sonioxCode == row["soniox"] as? String, "\(tag) soniox")
        expect(code.localeIdentifier == row["locale"] as? String, "\(tag) locale")
        expect(code.romanization.rawValue == row["romanization"] as? String, "\(tag) romanization")
        expect(code.romanizationSource.rawValue == row["romanizationSource"] as? String, "\(tag) romanizationSource")
        expect(code.voice == row["voice"] as? String, "\(tag) voice")
        expect(code.regions == row["regions"] as? [String], "\(tag) regions")
    }
} catch {
    failures += 1
    print("  FAIL reading langcodes.json: \(error)")
}
expect(LangCode(tag: "zh-Hans") == .zhHans, "zh-Hans")
expect(LangCode(tag: "zh-CN") == .zhHans, "zh-CN → zh-Hans")
expect(LangCode(tag: "zh_Hans_CN") == .zhHans, "zh_Hans_CN → zh-Hans")
expect(LangCode(tag: "zh-TW") == .zhHant, "zh-TW → zh-Hant")
expect(LangCode(tag: "zh-Hant-HK") == .zhHant, "zh-Hant-HK → zh-Hant")
expect(LangCode(tag: "ja-JP") == .ja, "ja-JP → ja")
expect(LangCode(tag: "en-CA") == .en, "en-CA → en")
expect(LangCode(tag: "fr") == nil, "fr → nil")
expect(LangCode.forRegion("cn") == .zhHans && LangCode.forRegion("JP") == .ja && LangCode.forRegion("HK") == .zhHant, "forRegion")

section("CategorySlug matches contracts/tables/categories.json")
do {
    let data = try Data(contentsOf: tables.appending(path: "categories.json"))
    let rows = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["categories"] as? [[String: Any]] ?? []
    expect(rows.count == CategorySlug.allCases.count, "same number of categories (\(rows.count))")
    for row in rows {
        let slug = row["slug"] as? String ?? "?"
        guard let category = CategorySlug(rawValue: slug) else {
            failures += 1
            print("  FAIL no CategorySlug for \(slug)")
            continue
        }
        expect(category.displayName == row["displayName"] as? String, "\(slug) displayName")
        expect(category.sfSymbol == row["sfSymbol"] as? String, "\(slug) sfSymbol")
        expect(category.starters == row["starters"] as? [String], "\(slug) starters")
    }
} catch {
    failures += 1
    print("  FAIL reading categories.json: \(error)")
}
expect((try? JSONDecoder().decode([CategorySlug].self, from: Data(#"["spa","cafe"]"#.utf8))) == [.other, .cafe], "unknown category decodes as other")

// MARK: - Configuration and errors

section("Configuration and error envelope")
expect(RyokoAPIConfiguration.validBaseURL("http://127.0.0.1:8792") != nil, "http localhost URL is valid")
expect(RyokoAPIConfiguration.validBaseURL("https://example.ts.net:10000/") != nil, "https URL is valid")
expect(RyokoAPIConfiguration.validBaseURL("ftp://example.com") == nil, "ftp is rejected")
expect(RyokoAPIConfiguration.validBaseURL("127.0.0.1:8792") == nil, "URL without a scheme is rejected")
expect(RyokoAPIConfiguration.validBaseURL("") == nil, "empty is rejected")
let suite = "ryoko.contract-check.\(UUID().uuidString)"
if let defaults = UserDefaults(suiteName: suite) {
    expect(RyokoAPIConfiguration.setBaseURLOverride("not a url", defaults: defaults) == false, "a bad override is refused")
    expect(RyokoAPIConfiguration.setBaseURLOverride("http://10.0.0.2:8792", defaults: defaults), "a good override is stored")
    expect(RyokoAPIConfiguration.baseURLOverride(defaults: defaults) == "http://10.0.0.2:8792", "override reads back")
    expect(RyokoAPIConfiguration.setBaseURLOverride(nil, defaults: defaults) && RyokoAPIConfiguration.baseURLOverride(defaults: defaults) == nil, "override clears")
    let first = RyokoAPIConfiguration.installId(defaults: defaults)
    expect(UUID(uuidString: first) != nil && RyokoAPIConfiguration.installId(defaults: defaults) == first, "install id is a stable UUID")
    defaults.removePersistentDomain(forName: suite)
}
let busyBody = (try? Data(contentsOf: examples.appending(path: "error.session-busy.response.json"))) ?? Data()
expect(LiveRyokoAPI.error(status: 409, body: busyBody).code == .sessionBusy, "409 body decodes to session_busy")
expect(LiveRyokoAPI.error(status: 502, body: Data("<html>".utf8)) == .http(status: 502), "non-envelope body gives .http")
expect(LiveRyokoAPI.mapped(URLError(.cancelled)) is CancellationError, "cancelled request maps to CancellationError")
expect((LiveRyokoAPI.mapped(URLError(.timedOut)) as? RyokoAPIError) == .transport(.timedOut), "timeout maps to .transport")

// MARK: - Tier 2 Translate contracts

section("Translate and Soniox key contracts")
do {
    let typed = TranslateRequest(text: "Less sweet", from: "en", to: "zh-Hans", situation: nil)
    let object = try json(typed)
    expect(object.keys.sorted() == ["from", "text", "to"], "a translate request without a situation omits the key")
    let key = SonioxKeyResponse(apiKey: "secret-value-123", expiresAt: "2026-10-05T07:01:00Z")
    let shown = [String(describing: key), String(reflecting: key), "\(key)"]
    var dumped = ""
    dump(key, to: &dumped)
    expect(!(shown + [dumped]).contains { $0.contains("secret-value-123") }, "a Soniox key never shows in a description or dump")
    expect(try json(key)["apiKey"] as? String == "secret-value-123", "but it encodes the key")
    expect(try json(SonioxKeyRequest()).isEmpty, "the soniox-key request body is {}")
} catch {
    failures += 1
    print("  FAIL translate contracts: \(error)")
}

/// An API with only the tier 1 methods, like the DEBUG Mimo script: the tier 2
/// defaults answer as if there's no server.
nonisolated struct ScriptOnlyAPI: RyokoAPI {
    func placeCard(_ request: PlaceCardRequest) async throws -> PlaceCardResponse { throw RyokoAPIError.http(status: 500) }
    func discover(_ request: DiscoverRequest) async throws -> DiscoverResponse { throw RyokoAPIError.http(status: 500) }
    func allergyCard(_ request: AllergyCardRequest) async throws -> AllergyCardResponse { throw RyokoAPIError.http(status: 500) }
    func mimoMessages(sessionId: String, request: MimoMessageRequest) -> AsyncThrowingStream<MimoEvent, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

// MARK: - Fixture API

section("FixtureRyokoAPI")
let fixtureAPI = FixtureRyokoAPI(source: .directory(examples), latency: .zero, eventInterval: .zero)
do {
    let tokyoRequest = try FixtureSource.directory(examples).decode(PlaceCardRequest.self, from: .placeCardTokyoRequest)
    let tokyoCard = try await fixtureAPI.placeCard(tokyoRequest)
    expect(tokyoCard.language == "ja" && tokyoCard.phrases.count == 3, "Tokyo request gets the Japanese card")
    let shanghaiRequest = try FixtureSource.directory(examples).decode(PlaceCardRequest.self, from: .placeCardRequest)
    let shanghaiCard = try await fixtureAPI.placeCard(shanghaiRequest)
    expect(shanghaiCard.language == "zh-Hans", "Shanghai request gets the Chinese card")
    let discoverRequest = try FixtureSource.directory(examples).decode(DiscoverRequest.self, from: .discoverRequest)
    let picks = try await fixtureAPI.discover(discoverRequest)
    expect(picks.places.count == 6, "discover returns 6 places")
    let mimoRequest = try FixtureSource.directory(examples).decode(MimoMessageRequest.self, from: .mimoMessageRequest)
    var events: [MimoEvent] = []
    for try await event in fixtureAPI.mimoMessages(sessionId: "session-xyz", request: mimoRequest) {
        events.append(event)
    }
    expect(events.first == .start(sessionId: "session-xyz", runId: "run_01"), "stream starts with the requested session id")
    expect(events.count == 12, "stream has 12 events (got \(events.count))")
    expect(events.last == .done(stopReason: .stop), "stream ends with done")
    let places = events.compactMap { event -> [ShownPlace]? in
        if case let .toolEnd(end) = event, case let .showPlaces(details) = end.details { details.places } else { nil }
    }
    expect(places.first?.count == 3, "show_places carries 3 places")

    let source = FixtureSource.directory(examples)
    let typedTokyo = try source.decode(TranslateRequest.self, from: .translateTokyoRequest)
    let ramen = try await fixtureAPI.translate(typedTokyo).translation
    expect(ramen == "麺かため、油少なめでお願いします。", "Japanese typed text gets the ramen order")
    var typedShanghai = try source.decode(TranslateRequest.self, from: .translateRequest)
    typedShanghai.situation = nil
    let cafe = try await fixtureAPI.translate(typedShanghai).translation
    expect(cafe.contains("少糖"), "Chinese typed text gets the café order, situation or not")
    let same = TranslateRequest(text: " Hello ", from: "en", to: "en", situation: nil)
    let echoed = try await fixtureAPI.translate(same).translation
    expect(echoed == "Hello", "the same language comes back as typed")
    do {
        _ = try await fixtureAPI.sonioxKey()
        failures += 1
        print("  FAIL the fixture API minted a Soniox key")
    } catch let error as RyokoAPIError {
        expect(error == .notConfigured("fixtures have no Soniox key server"), "fixtures have no key server, so Translate falls back")
    }
    let stand_in = ScriptOnlyAPI()
    do {
        _ = try await stand_in.translate(typedTokyo)
        failures += 1
        print("  FAIL a stand-in API translated")
    } catch let error as RyokoAPIError {
        expect(error == .notConfigured("translate"), "a stand-in API without translate answers notConfigured")
    }

    let busy = FixtureRyokoAPI.sessionBusy(source: .directory(examples))
    do {
        for try await _ in busy.mimoMessages(sessionId: "s", request: mimoRequest) {}
        failures += 1
        print("  FAIL session-busy fixture didn't throw")
    } catch let error as RyokoAPIError {
        expect(error.code == .sessionBusy && error.isRetryable, "session-busy fixture throws a typed, retryable error")
    }
} catch {
    failures += 1
    print("  FAIL fixture API: \(error)")
}

// MARK: - Live server (optional)

if let base = env["RYOKO_LIVE_BASE_URL"], let token = env["RYOKO_APP_TOKEN"], !token.isEmpty {
    section("LiveRyokoAPI against \(base)")
    let installId = UUID().uuidString.lowercased()
    func live(_ token: String) -> LiveRyokoAPI {
        LiveRyokoAPI(configuration: {
            guard let url = RyokoAPIConfiguration.validBaseURL(base) else { throw RyokoAPIError.notConfigured("base") }
            return RyokoAPIConfiguration(baseURL: url, appToken: token, installId: installId, clientVersion: "ios/contract-check")
        })
    }
    let api = live(token)
    let source = FixtureSource.directory(examples)
    do {
        let card = try await api.placeCard(source.decode(PlaceCardRequest.self, from: .placeCardRequest))
        expect(!card.phrases.isEmpty, "place-card returns phrases (\(card.language), \(card.phrases.count))")
        let picks = try await api.discover(source.decode(DiscoverRequest.self, from: .discoverRequest))
        expect(!picks.places.isEmpty, "discover returns places (\(picks.places.count))")
        let allergy = try await api.allergyCard(source.decode(AllergyCardRequest.self, from: .allergyCardRequest))
        expect(!allergy.items.isEmpty && !allergy.reviewed, "allergy-card returns unreviewed items")
        let typedStarted = ContinuousClock.now
        let typed = try await api.translate(source.decode(TranslateRequest.self, from: .translateTokyoRequest))
        expect(!typed.translation.isEmpty, "translate returns text (\(typed.translation), \(ContinuousClock.now - typedStarted))")
        do {
            let key = try await api.sonioxKey()
            // Never print the key: its length only.
            expect(!key.apiKey.isEmpty && (try? Date(key.expiresAt, strategy: .iso8601)) != nil, "soniox-key returns a key (\(key.apiKey.count) characters) and an ISO 8601 expiry")
        } catch let RyokoAPIError.server(status, body) where status == 503 && body.code == .modelError {
            print("  note: this server has no SONIOX_API_KEY (503); the app falls back to its own key")
        }

        let request = try source.decode(MimoMessageRequest.self, from: .mimoMessageRequest)
        let sessionId = UUID().uuidString.lowercased()
        var kinds: [String] = []
        var firstEventAfter: Duration?
        let started = ContinuousClock.now
        for try await event in api.mimoMessages(sessionId: sessionId, request: request) {
            if firstEventAfter == nil { firstEventAfter = ContinuousClock.now - started }
            switch event {
            case .start: kinds.append("start")
            case .text: kinds.append("text")
            case .phrase: kinds.append("phrase")
            case .toolStart: kinds.append("tool_start")
            case .toolEnd: kinds.append("tool_end")
            case .done: kinds.append("done")
            case .error(let body): kinds.append("error(\(body.code.rawValue))")
            case .unknown(let type): kinds.append("unknown(\(type))")
            }
        }
        print("  stream: \(kinds.count) events, first after \(firstEventAfter.map { "\($0)" } ?? "-"): \(kinds.joined(separator: " "))")
        expect(kinds.first == "start" && kinds.last == "done", "Mimo stream runs start → done")

        // A second message while the first run is still streaming gets 409 session_busy.
        let busySession = UUID().uuidString.lowercased()
        var running = api.mimoMessages(sessionId: busySession, request: request).makeAsyncIterator()
        _ = try await running.next()
        do {
            for try await _ in api.mimoMessages(sessionId: busySession, request: request) {}
            print("  note: the second message wasn't busy (the first run may already have finished)")
        } catch let error as RyokoAPIError {
            expect(error.code == .sessionBusy && error.isRetryable, "second message while streaming gives a retryable session_busy (\(error))")
        }
        while try await running.next() != nil {}

        // Leaving the loop early cancels the request; the server frees the session.
        // (Inside a function: in top-level code the loop's iterator is a global and
        // is never released, so the stream would never see the consumer leave.)
        func readUntilFirstText(_ stream: AsyncThrowingStream<MimoEvent, any Error>) async throws {
            for try await event in stream {
                if case .text = event { break }
            }
        }
        let leftSession = UUID().uuidString.lowercased()
        try await readUntilFirstText(api.mimoMessages(sessionId: leftSession, request: request))
        try await Task.sleep(for: .milliseconds(200))
        var again: [MimoEvent] = []
        for try await event in api.mimoMessages(sessionId: leftSession, request: request) {
            again.append(event)
        }
        expect(again.last == .done(stopReason: .stop), "after leaving a stream early, the same session answers again")
    } catch {
        failures += 1
        print("  FAIL live: \(error)")
    }
    do {
        _ = try await live("wrong-token").placeCard(source.decode(PlaceCardRequest.self, from: .placeCardRequest))
        failures += 1
        print("  FAIL a wrong token was accepted")
    } catch let error as RyokoAPIError {
        expect(error.code == .unauthorized, "a wrong token gives unauthorized (\(error))")
    } catch {
        failures += 1
        print("  FAIL wrong token: \(error)")
    }
} else {
    print("\n(Skipping the live server check. Run with --live to include it.)")
}

print("\n\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
