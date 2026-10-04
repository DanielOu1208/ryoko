import Foundation

// A check of Translate's pure parts over synthetic Soniox streams: the turn
// rule (en→zh→en, late translations, false single-token flips, endpoints, the
// panes never clearing), the tilt rule, the pair, and the Soniox message
// shapes. It runs on the Mac, with no simulator, key or microphone:
//
//   ROOT=$(git rev-parse --show-toplevel); OUT="$ROOT/ios/.build/turn-rule-check"; mkdir -p "$OUT"
//   xcrun swiftc -swift-version 6 -default-isolation MainActor -parse-as-library \
//     -D TURN_RULE_CHECK_MAIN -module-name TurnRuleCheck -o "$OUT/turn-rule-check" \
//     "$ROOT/ios/Shared/LangCode.swift" \
//     "$ROOT"/ios/Ryoko/Translate/{SonioxProtocol,TranslatePair,TurnRule,TiltRule,CannedConversation,TurnRuleCheck}.swift \
//   && "$OUT/turn-rule-check"
//
// It exits non-zero if any case fails. In a DEBUG app build the same cases
// run with `-RyokoTranslateSelfCheck 1` and print to the log.

#if DEBUG || TURN_RULE_CHECK_MAIN
nonisolated enum TurnRuleCheck {
    nonisolated struct Outcome: Sendable {
        var name: String
        var failures: [String]
        var passed: Bool { failures.isEmpty }
    }

    static let enZh = TranslatePair(home: PairLanguage(.en), other: PairLanguage(.zhHans))
    static let enJa = TranslatePair(home: PairLanguage(.en), other: PairLanguage(.ja))

    static func runAll() -> [Outcome] {
        [
            check("en→zh→en with endpoints", enZhEnWithEndpoints),
            check("en→zh→en without endpoints (rule only)", enZhEnWithoutEndpoints),
            check("late translations attach to their turn", lateTranslations),
            check("translation after <end> attaches to the closed turn", translationAfterEnd),
            check("false single-token flip inside a turn is absorbed", falseFlipAbsorbed),
            check("false flip right before <end> stays in the turn", falseFlipBeforeEnd),
            check("one CJK character is not a new turn, two are", cjkThreshold),
            check("one English word is not a new turn, two are", englishThreshold),
            check("a third language never starts a turn", thirdLanguage),
            check("panes never clear before the new turn has text", panesNeverClear),
            check("live words show before the first final token", provisionalDisplay),
            check("orphan translations are dropped", orphanTranslation),
            check("ending the session keeps live words", endSessionKeepsTail),
            check("speakers and tags follow the pair", speakersAndTags),
            check("manual: a turn stays locked to its speaker", manualLocked),
            check("manual: hand-over waits for <fin>, then the panes keep the old turn", manualHandOver),
            check("manual: late translations and stray tags", manualTranslations),
            check("manual: hand-over with nothing heard is instant; tapping back cancels", manualQuickSwitches),
            check("manual: a forced hand-over and the session end", manualForcedAndEnd),
            check("manual: canned conversation with hand-overs", manualCanned),
            check("canned zh conversation", cannedConversation(enZh)),
            check("canned ja conversation", cannedConversation(enJa)),
            check("tilt: flat and tipped away switch to face to face", tiltEnters),
            check("tilt: hysteresis and debounce", tiltHysteresis),
            check("tilt: sideways and face down are ignored", tiltIgnores),
            check("pair from the situation", pairResolution),
            check("Soniox messages decode, errors map", sonioxMessages),
            check("typed turns and edits (tier 2)", typedTurnsAndEdits),
            check("Type mode text: return is Done, 500 characters at most", typedTextRules),
        ]
    }

    // MARK: Type mode and editing (tier 2)

    private static func typedTurnsAndEdits(_ e: inout Expect) {
        var b = TurnBuilder(pair: enZh)
        b.apply(en("Hi, could I get a milk tea?") + [end])
        b.apply(tr("你好，我可以要一杯奶茶吗？", from: "en", to: "zh"))
        b.apply(zh("好的，中杯还是大杯？") + [end])
        b.apply(tr("Sure, medium or large?", from: "zh", to: "en"))
        b.endSession()
        var log = TurnLog()
        log.archive(b.turns)
        e.equal(log.nextId, 3, "ids continue after the session's turns")
        e.equal(log.latestEditable?.id, 1, "your latest turn is the editable one; theirs isn't")
        e.equal(log.turns[1].isEditable, false, "their turn can't be edited")

        let typed = log.addTyped(pair: enZh, text: "Medium, no ice.", translation: "中杯，去冰。")
        e.equal(typed.id, 3, "typed turn id")
        e.equal(typed.speaker, .me, "typed turns are yours")
        e.equal(typed.source, .typed, "source")
        e.equal(typed.closedBy, .typed, "closed as it's added")
        e.equal(typed.originalTag, "en", "your language")
        e.equal(typed.translationTag, "zh-Hans", "their language")
        e.equal(log.latestEditable?.id, 3, "the typed turn is now your latest")

        // Editing an older turn keeps it on screen; editing the latest doesn't need to.
        e.equal(log.edit(id: 1, original: "Hi, could I get a jasmine tea?", translation: "你好，我可以要一杯茉莉花茶吗？"), true, "edit applies")
        e.equal(log.turns[0].original, "Hi, could I get a jasmine tea?", "words replaced")
        e.equal(log.turns[0].translation, "你好，我可以要一杯茉莉花茶吗？", "translation replaced")
        e.equal(log.turns[0].edited, true, "marked edited")
        e.equal(log.turns[0].source, .voice, "still a spoken turn")
        e.equal(log.focused?.id, 1, "an edited older turn stays on screen")
        e.equal(log.edit(id: 2, original: "x", translation: "y"), false, "their turn can't be edited")
        e.equal(log.turns[1].original, "好的，中杯还是大杯？", "their words untouched")
        e.equal(log.edit(id: 99, original: "x", translation: "y"), false, "no such turn")
        log.addTyped(pair: enZh, text: "Thanks.", translation: "谢谢。")
        e.equal(log.focusedId, nil, "a new turn takes the panes back")
        e.equal(log.edit(id: 4, original: "Thank you.", translation: "谢谢你。"), true, "edit the latest")
        e.equal(log.focusedId, nil, "the latest is on screen anyway")

        // The next session's ids follow on.
        let next = TurnBuilder(pair: enZh, firstId: log.nextId)
        e.equal(next.upcomingId, 5, "next session starts after typed turns")
    }

    private static func typedTextRules(_ e: inout Expect) {
        e.equal(TypedText.accept("Less sweet").text, "Less sweet", "plain text")
        e.equal(TypedText.accept("Less sweet").submitted, false, "no return, no Done")
        let returned = TypedText.accept("Less sweet\n")
        e.equal(returned.text, "Less sweet", "the newline is dropped")
        e.equal(returned.submitted, true, "return means Done")
        e.equal(TypedText.accept(String(repeating: "a", count: 600)).text.count, 500, "cut at 500")
        e.equal(TypedText.request("   "), nil, "blank is nothing to translate")
        e.equal(TypedText.request("  Less sweet  "), "Less sweet", "trimmed")
    }

    // MARK: Turn rule cases

    private static func enZhEnWithEndpoints(_ e: inout Expect) {
        var b = TurnBuilder(pair: enZh)
        b.apply(en("Hi, could I get a milk tea?") + [end])
        b.apply(tr("你好，我可以要一杯奶茶吗？", from: "en", to: "zh"))
        b.apply(zh("好的，中杯还是大杯？") + [end])
        b.apply(tr("Sure, medium or large?", from: "zh", to: "en"))
        b.apply(en("Medium, please.") + [end])
        b.apply(tr("中杯，谢谢。", from: "en", to: "zh"))
        e.equal(b.turns.map(\.language), ["en", "zh", "en"], "languages")
        e.equal(b.turns.map(\.speaker), [.me, .them, .me], "speakers")
        e.equal(b.turns.map(\.original), ["Hi, could I get a milk tea?", "好的，中杯还是大杯？", "Medium, please."], "originals")
        e.equal(b.turns.map(\.translation), ["你好，我可以要一杯奶茶吗？", "Sure, medium or large?", "中杯，谢谢。"], "translations")
        e.equal(b.turns.map(\.closedBy), [.endpoint, .endpoint, .endpoint], "closed by <end>")
        e.equal(b.absorbedFlips, 0, "no flips")
    }

    private static func enZhEnWithoutEndpoints(_ e: inout Expect) {
        var b = TurnBuilder(pair: enZh)
        b.apply(en("Could I get a milk tea?"))
        b.apply(zh("好的，中杯还是大杯？"))
        b.apply(en("Medium, please."))
        e.equal(b.turns.map(\.language), ["en", "zh", "en"], "languages")
        e.equal(b.turns.map(\.closedBy), [.languageSwitch, .languageSwitch, nil], "closed by the rule; last still open")
        e.equal(b.turns.map(\.original), ["Could I get a milk tea?", "好的，中杯还是大杯？", "Medium, please."], "originals keep every token")
    }

    private static func lateTranslations(_ e: inout Expect) {
        var b = TurnBuilder(pair: enZh)
        b.apply(en("Could I get a milk tea?") + [end])
        // They answer before the English line's translation arrives.
        b.apply(zh("好的，中杯"))
        e.equal(b.display?.language, "zh", "panes show their turn")
        b.apply(tr("我可以要一杯奶茶吗？", from: "en", to: "zh"))
        b.apply(zh("还是大杯？") + [end])
        // You answer before their translation arrives.
        b.apply(en("Medium, please"))
        b.apply(tr("Sure, medium or large?", from: "zh", to: "en"))
        b.apply(en(".") + [end])
        b.apply(tr("中杯，谢谢。", from: "en", to: "zh"))
        e.equal(b.turns.map(\.translation), ["我可以要一杯奶茶吗？", "Sure, medium or large?", "中杯，谢谢。"], "each translation on its own turn")
        e.equal(b.lateTranslationTokens > 0, true, "late tokens counted")
        e.equal(b.orphanTranslations, 0, "no orphans")
    }

    private static func translationAfterEnd(_ e: inout Expect) {
        var b = TurnBuilder(pair: enZh)
        b.apply(zh("一共十八块。") + [end])
        e.equal(b.turns.first?.isClosed, true, "closed by <end>")
        b.apply(tr("That's eighteen yuan.", from: "zh", to: "en"))
        e.equal(b.turns.first?.translation, "That's eighteen yuan.", "attached after <end>")
        e.equal(b.turns.count, 1, "no new turn from a translation")
    }

    private static func falseFlipAbsorbed(_ e: inout Expect) {
        var b = TurnBuilder(pair: enZh)
        // Soniox tags one token of an English sentence as Chinese.
        b.apply(en("Can I have"))
        b.apply([original(" tea", "zh")])
        b.apply(en(" with less sugar?"))
        // And one token of a Chinese sentence as English.
        b.apply([end])
        b.apply(zh("好的，"))
        b.apply([original(" OK", "en")])
        b.apply(zh("马上来。") + [end])
        e.equal(b.turns.map(\.language), ["en", "zh"], "two turns, no flips")
        e.equal(b.turns.map(\.original), ["Can I have tea with less sugar?", "好的， OK马上来。"], "flipped tokens kept in place")
        e.equal(b.absorbedFlips, 2, "two flips absorbed")
    }

    private static func falseFlipBeforeEnd(_ e: inout Expect) {
        var b = TurnBuilder(pair: enZh)
        b.apply(en("Thank you"))
        b.apply([original(" 谢", "zh"), end])
        e.equal(b.turns.count, 1, "one turn")
        e.equal(b.turns.first?.original, "Thank you 谢", "the flip stays in the turn")
        e.equal(b.turns.first?.closedBy, .endpoint, "closed by <end>")
        e.equal(b.pending.isEmpty, true, "nothing pending")
    }

    private static func cjkThreshold(_ e: inout Expect) {
        var b = TurnBuilder(pair: enZh)
        b.apply(en("Is this one spicy"))
        b.apply([original("不", "zh")])
        e.equal(b.turns.count, 1, "one CJK character waits")
        b.apply([original("辣", "zh")])
        e.equal(b.turns.map(\.language), ["en", "zh"], "two CJK characters start a turn")
        e.equal(b.turns.last?.original, "不辣", "the new turn starts with both")

        var two = TurnBuilder(pair: enZh)
        two.apply(en("Is this spicy"))
        two.apply([original("不辣", "zh")])
        e.equal(two.turns.count, 2, "one token with two CJK characters starts a turn")

        var ja = TurnBuilder(pair: enJa)
        ja.apply(en("How much"))
        ja.apply([original("は", "ja")])
        e.equal(ja.turns.count, 1, "one kana waits")
        ja.apply([original("い", "ja")])
        e.equal(ja.turns.map(\.language), ["en", "ja"], "two kana start a turn")
    }

    private static func englishThreshold(_ e: inout Expect) {
        var b = TurnBuilder(pair: enZh)
        b.apply(zh("要不要加冰"))
        b.apply([original(" No", "en")])
        e.equal(b.turns.count, 1, "one English word waits")
        b.apply([original(",", "en")])
        e.equal(b.turns.count, 1, "punctuation doesn't count")
        b.apply([original(" thanks", "en")])
        e.equal(b.turns.map(\.language), ["zh", "en"], "two English words start a turn")
        e.equal(b.turns.last?.original, "No, thanks", "with the punctuation between")
    }

    private static func thirdLanguage(_ e: inout Expect) {
        var b = TurnBuilder(pair: enZh)
        b.apply(en("Two of"))
        b.apply([original(" 김치", "ko"), original(" 볶음밥", "ko")])
        b.apply(en(" please") + [end])
        e.equal(b.turns.count, 1, "Korean guesses stay in the English turn")
        e.equal(b.turns.first?.original, "Two of 김치 볶음밥 please", "text kept")
    }

    private static func panesNeverClear(_ e: inout Expect) {
        var b = TurnBuilder(pair: enZh)
        b.apply(en("Could I get a milk tea?") + [end])
        b.apply(tr("我可以要一杯奶茶吗？", from: "en", to: "zh"))
        // They start speaking: only non-final words so far.
        b.apply(live("好的", "zh"))
        e.equal(b.display?.id, b.turns.first?.id, "still the first turn while their words are live")
        e.equal(b.display?.original, "Could I get a milk tea?", "panes keep the old text")
        // One final Chinese token: below the threshold after <end>? A closed turn
        // means the next final token opens the new turn, which then has text.
        b.apply([original("好", "zh")] + live("的", "zh"))
        e.equal(b.display?.language, "zh", "new turn shown once it has text")
        e.equal(b.display?.original, "好的", "with its live words")

        // Without an endpoint: other-language tokens below the threshold don't show.
        var c = TurnBuilder(pair: enZh)
        c.apply(en("Could I get a milk tea"))
        c.apply([original("好", "zh")] + live("的", "zh"))
        e.equal(c.display?.language, "en", "still the English turn")
        e.equal(c.display?.original, "Could I get a milk tea", "without the pending Chinese")
        c.apply([original("的", "zh")])
        e.equal(c.display?.original, "好的", "switches once the new turn has text")
    }

    private static func provisionalDisplay(_ e: inout Expect) {
        var b = TurnBuilder(pair: enZh)
        e.equal(b.display == nil, true, "nothing before anyone speaks")
        b.apply(live(" Hi", "en") + live(" there", "en"))
        e.equal(b.display?.original, "Hi there", "live words show")
        e.equal(b.display?.speaker, .me, "as you")
        e.equal(b.display?.id, b.upcomingId, "with the id the turn will get")
        b.apply(en("Hi"))
        e.equal(b.display?.id, b.turns.first?.id, "same id once final")
    }

    private static func orphanTranslation(_ e: inout Expect) {
        var b = TurnBuilder(pair: enZh)
        b.apply(tr("你好", from: "en", to: "zh"))
        e.equal(b.turns.count, 0, "no turn from a translation")
        e.equal(b.orphanTranslations, 2, "counted")
    }

    private static func endSessionKeepsTail(_ e: inout Expect) {
        var b = TurnBuilder(pair: enZh)
        b.apply(en("Thank you") + live(" so much", "en"))
        b.apply([original("谢", "zh")] + live(" so much", "en"))
        b.endSession()
        e.equal(b.turns.count, 1, "one turn")
        e.equal(b.turns.first?.original, "Thank you谢 so much", "pending and live words kept")
        e.equal(b.turns.first?.closedBy, .sessionEnd, "closed by the session end")
        e.equal(b.tail.isEmpty, true, "no tail left")
    }

    private static func speakersAndTags(_ e: inout Expect) {
        var b = TurnBuilder(pair: enZh, firstId: 7)
        b.apply(en("Hello") + [end] + zh("你好") + [end])
        e.equal(b.turns.map(\.id), [7, 8], "ids continue from firstId")
        e.equal(b.turns.map(\.originalTag), ["en", "zh-Hans"], "original tags")
        e.equal(b.turns.map(\.translationTag), ["zh-Hans", "en"], "translation tags")
        e.equal(b.history.count, 2, "history lists both")
    }

    private static func cannedConversation(_ pair: TranslatePair) -> (inout Expect) -> Void {
        { e in
            var b = TurnBuilder(pair: pair)
            var lastShown: Int?
            for step in CannedConversation.steps(for: pair, pace: 0) {
                b.apply(step.response.tokens)
                let shown = b.display?.id
                if let lastShown { e.equal(shown != nil, true, "display never empties after \(lastShown)") }
                lastShown = shown ?? lastShown
            }
            let lines = CannedConversation.lines(for: pair)
            e.equal(b.turns.map(\.speaker), lines.map(\.speaker), "speakers")
            e.equal(b.turns.map(\.original), lines.map(\.said), "originals")
            e.equal(b.turns.map(\.translation), lines.map(\.translated), "translations, including the late one")
            e.equal(b.lateTranslationTokens > 0, true, "one translation arrived late")
        }
    }

    // MARK: Tilt

    private static func gravity(elevation degrees: Double) -> (Double, Double, Double) {
        let radians = degrees * .pi / 180
        return (0, -sin(radians), -cos(radians))
    }

    private static func feed(_ rule: inout TiltRule, elevation: Double, from start: Double, seconds: Double) -> TranslateLayout {
        let g = gravity(elevation: elevation)
        var t = start
        var layout = rule.layout
        while t <= start + seconds {
            layout = rule.update(x: g.0, y: g.1, z: g.2, at: t)
            t += 0.1
        }
        return layout
    }

    private static func tiltEnters(_ e: inout Expect) {
        var flat = TiltRule()
        e.equal(feed(&flat, elevation: 85, from: 0, seconds: 1), .upright, "held up: upright")
        e.equal(feed(&flat, elevation: 10, from: 1.1, seconds: 1), .faceToFace, "near flat: face to face")
        var away = TiltRule()
        e.equal(feed(&away, elevation: -40, from: 0, seconds: 1), .faceToFace, "top tipped away: face to face")
        e.equal(TiltRule.elevation(x: 0, y: -1, z: 0).rounded(), 90, "upright elevation")
        e.equal(TiltRule.elevation(x: 0, y: 0, z: -1).rounded(), 0, "flat elevation")
    }

    private static func tiltHysteresis(_ e: inout Expect) {
        var rule = TiltRule()
        e.equal(feed(&rule, elevation: 25, from: 0, seconds: 2), .upright, "25° from upright (reading at an angle): stays upright")
        e.equal(feed(&rule, elevation: 10, from: 2.1, seconds: 0.2), .upright, "a 0.2 s dip doesn't switch")
        e.equal(feed(&rule, elevation: 25, from: 2.4, seconds: 1), .upright, "back above 15° resets the debounce")
        e.equal(feed(&rule, elevation: 10, from: 3.5, seconds: 1), .faceToFace, "held below 15°: switches")
        e.equal(feed(&rule, elevation: 30, from: 4.6, seconds: 2), .faceToFace, "30° from flat: stays face to face")
        e.equal(feed(&rule, elevation: 50, from: 6.7, seconds: 0.2), .faceToFace, "a 0.2 s lift doesn't switch")
        e.equal(feed(&rule, elevation: 50, from: 7.0, seconds: 1), .upright, "held above 35°: back to upright")
    }

    private static func tiltIgnores(_ e: inout Expect) {
        var sideways = TiltRule()
        var t = 0.0
        while t < 2 { sideways.update(x: -1, y: 0, z: 0, at: t); t += 0.1 }
        e.equal(sideways.layout, .upright, "landscape upright doesn't count as flat")
        var faceDown = TiltRule()
        t = 0
        while t < 2 { faceDown.update(x: 0, y: 0, z: 1, at: t); t += 0.1 }
        e.equal(faceDown.layout, .upright, "face down is ignored")
    }

    // MARK: Pair and Soniox

    private static func pairResolution(_ e: inout Expect) {
        let auto = PairChoice.resolve(homeTag: "en", situationLanguage: "zh-Hans")
        e.equal(auto?.label, "English ⇄ Chinese", "home ⇄ local")
        e.equal(auto?.sonioxConfig, SonioxConfig(languageA: "en", languageB: "zh"), "Soniox codes")
        e.equal(PairChoice.resolve(homeTag: "en", situationLanguage: "en") == nil, true, "same language: no pair")
        e.equal(PairChoice.resolve(homeTag: "en", situationLanguage: nil) == nil, true, "no situation: no pair")
        e.equal(PairChoice.resolve(homeTag: "en", situationLanguage: "zh-Hans", manualOther: "ja")?.other.tag, "ja", "manual pick wins")
        e.equal(PairChoice.resolve(homeTag: "en", situationLanguage: "fr")?.other.sonioxCode, "fr", "a language without a row")
        e.equal(PairChoice.options(situationLanguage: "ko").last?.tag, "ko", "offered in the picker")
    }

    private static func sonioxMessages(_ e: inout Expect) {
        let rejected = #"{"tokens":[],"final_audio_proc_ms":0,"total_audio_proc_ms":0,"error_code":401,"error_type":"unauthenticated","error_message":"Incorrect API key provided."}"#
        let response = try? JSONDecoder().decode(SonioxResponse.self, from: Data(rejected.utf8))
        e.equal(response?.problem, .keyRejected, "401 maps to keyRejected")
        e.equal(response?.problem?.title, "Soniox key was rejected", "401 copy")
        e.equal(TranslateProblem.soniox(code: 402, type: nil, message: nil), .balanceExhausted, "402")
        e.equal(TranslateProblem.soniox(code: 503, type: nil, message: nil), .serviceUnavailable, "503")
        e.equal(TranslateProblem.network(URLError(.notConnectedToInternet)), .offline, "offline")

        let tokens = #"{"tokens":[{"text":"你好","start_ms":120,"end_ms":480,"confidence":0.98,"is_final":true,"language":"zh","translation_status":"original"},{"text":" Hello","is_final":false,"language":"en","translation_status":"translation","source_language":"zh"},{"text":"<end>","is_final":true}],"final_audio_proc_ms":480,"total_audio_proc_ms":600}"#
        let decoded = try? JSONDecoder().decode(SonioxResponse.self, from: Data(tokens.utf8))
        e.equal(decoded?.tokens.count, 3, "three tokens")
        e.equal(decoded?.tokens.first?.isOriginal, true, "original")
        e.equal(decoded?.tokens[1].isTranslation, true, "translation")
        e.equal(decoded?.tokens[1].sourceLanguage, "zh", "source language")
        e.equal(decoded?.tokens.last?.isEndpoint, true, "endpoint")
        e.equal(decoded?.finished, false, "not finished")

        let message = (try? SonioxConfig(languageA: "en", languageB: "zh").message(apiKey: "test-key")) ?? ""
        let json = (try? JSONSerialization.jsonObject(with: Data(message.utf8))) as? [String: Any] ?? [:]
        e.equal(json["model"] as? String, "stt-rt-v5", "model")
        e.equal(json["audio_format"] as? String, "pcm_s16le", "format")
        e.equal(json["sample_rate"] as? Int, 16000, "sample rate")
        e.equal(json["num_channels"] as? Int, 1, "mono")
        e.equal(json["language_hints"] as? [String], ["en", "zh"], "hints")
        e.equal(json["language_hints_strict"] as? Bool, true, "strict hints")
        e.equal(json["enable_language_identification"] as? Bool, true, "language ID")
        e.equal(json["enable_endpoint_detection"] as? Bool, true, "endpoints")
        let translation = json["translation"] as? [String: String]
        e.equal(translation, ["type": "two_way", "language_a": "en", "language_b": "zh"], "two-way translation")
    }

    // MARK: Manual turns (#68)

    private static func manualLocked(_ e: inout Expect) {
        var b = TurnBuilder(pair: enZh, mode: .manual)
        b.apply(en("Could I get a"))
        // Soniox tags a few words as Chinese: still your turn, no new turn.
        b.apply([original("奶", "zh"), original("茶", "zh")])
        b.apply(en(" please") + [end])
        b.apply(en(" No ice."))
        e.equal(b.turns.count, 1, "one turn")
        e.equal(b.turns.first?.speaker, .me, "yours")
        e.equal(b.turns.first?.original, "Could I get a奶茶 please No ice.", "every word, across <end>")
        e.equal(b.turns.first?.isClosed, false, "a pause doesn't close it")
        e.equal(b.hearsOtherSpeaker, false, "two Chinese characters aren't a hint")
        b.apply(zh("要中杯还是大杯"))
        e.equal(b.turns.count, 1, "still one turn")
        e.equal(b.hearsOtherSpeaker, true, "a run of Chinese suggests a hand-over")
        b.apply(en(" Medium"))
        e.equal(b.hearsOtherSpeaker, false, "your language again clears it")
    }

    private static func manualHandOver(_ e: inout Expect) {
        var b = TurnBuilder(pair: enZh, mode: .manual)
        b.apply(en("Could I get a milk tea") + live("?", "en"))
        e.equal(b.handOver(to: .them), true, "asks Soniox to finalize")
        e.equal(b.activeSpeaker, .them, "the controls show them at once")
        // Your last word turns final before <fin>: it stays yours.
        b.apply([original("?", "en")])
        e.equal(b.turns.count, 1, "no new turn before <fin>")
        b.apply([SonioxToken(text: SonioxToken.finalizeMarker, isFinal: true, language: nil)])
        e.equal(b.turns.first?.closedBy, .handOver, "closed by the hand-over")
        e.equal(b.turns.first?.original, "Could I get a milk tea?", "with its last word")
        e.equal(b.speaker, .them, "their turn now")
        e.equal(b.display?.original, "Could I get a milk tea?", "panes keep your turn")
        b.apply(live("好的", "zh"))
        e.equal(b.display?.speaker, .them, "their live words show as theirs")
        e.equal(b.display?.original, "好的", "with their text")
        b.apply(zh("好的") + [original(" OK", "en")])
        e.equal(b.turns.count, 2, "their turn")
        e.equal(b.turns.last?.speaker, .them, "as them")
        e.equal(b.turns.last?.original, "好的 OK", "an English word stays in their turn")
    }

    private static func manualTranslations(_ e: inout Expect) {
        var b = TurnBuilder(pair: enZh, mode: .manual)
        b.apply(en("Could I get a milk tea?"))
        _ = b.handOver(to: .them)
        b.apply([SonioxToken(text: SonioxToken.finalizeMarker, isFinal: true, language: nil)])
        b.apply(zh("好的"))
        // Your line's translation arrives after their turn started.
        b.apply(tr("我可以要一杯奶茶吗？", from: "en", to: "zh"))
        b.apply(tr("Sure", from: "zh", to: "en"))
        e.equal(b.turns.map(\.translation), ["我可以要一杯奶茶吗？", "Sure"], "each on its own turn")
        // An English word in their turn: its translation stays with their turn.
        b.apply([original(" OK", "en")])
        b.apply(tr("好", from: "en", to: "zh"))
        e.equal(b.turns.last?.translation, "Sure好", "kept, in their turn")
        e.equal(b.strayTranslationTokens, 1, "counted as stray")
        e.equal(b.turns.first?.translation, "我可以要一杯奶茶吗？", "your turn untouched")
    }

    private static func manualQuickSwitches(_ e: inout Expect) {
        var b = TurnBuilder(pair: enZh, mode: .manual)
        e.equal(b.handOver(to: .them), false, "nothing heard: no finalize")
        e.equal(b.speaker, .them, "their turn at once")
        b.apply(zh("你好"))
        e.equal(b.turns.first?.speaker, .them, "first turn is theirs")
        e.equal(b.handOver(to: .me), true, "finalize")
        e.equal(b.handOver(to: .them), false, "tapping back cancels")
        e.equal(b.activeSpeaker, .them, "still theirs")
        b.apply([SonioxToken(text: SonioxToken.finalizeMarker, isFinal: true, language: nil)])
        e.equal(b.turns.first?.isClosed, false, "a stale <fin> closes nothing")
        b.apply(zh("吗"))
        e.equal(b.turns.count, 1, "same turn")
        e.equal(b.handOver(to: .them), false, "tapping the speaker does nothing")
    }

    private static func manualForcedAndEnd(_ e: inout Expect) {
        var b = TurnBuilder(pair: enZh, mode: .manual)
        b.apply(en("Thank you"))
        _ = b.handOver(to: .them)
        b.completeHandOver(force: true)
        e.equal(b.turns.first?.closedBy, .handOver, "closed without <fin>")
        e.equal(b.speaker, .them, "their turn")
        b.apply([SonioxToken(text: SonioxToken.finalizeMarker, isFinal: true, language: nil)])
        e.equal(b.turns.count, 1, "a late <fin> does nothing")
        b.apply(zh("不客气") + live("。", "zh"))
        _ = b.handOver(to: .me)
        b.endSession()
        e.equal(b.turns.map(\.closedBy), [.handOver, .sessionEnd], "the session end closes the last")
        e.equal(b.turns.last?.original, "不客气。", "with its live words")
        e.equal(b.speaker, .me, "the waiting hand-over still counts for next time")
    }

    private static func manualCanned(_ e: inout Expect) {
        var b = TurnBuilder(pair: enZh, mode: .manual)
        for step in CannedConversation.steps(for: enZh, pace: 0) {
            if let speaker = step.speaker, b.handOver(to: speaker) {
                b.apply([SonioxToken(text: SonioxToken.finalizeMarker, isFinal: true, language: nil)])
            }
            b.apply(step.response.tokens)
        }
        b.endSession()
        let lines = CannedConversation.lines(for: enZh)
        e.equal(b.turns.map(\.speaker), lines.map(\.speaker), "speakers")
        e.equal(b.turns.map(\.original), lines.map(\.said), "originals")
        e.equal(b.turns.map(\.translation), lines.map(\.translated), "translations")
    }

    // MARK: Helpers

    nonisolated struct Expect {
        var failures: [String] = []
        mutating func equal<T: Equatable>(_ actual: T, _ expected: T, _ what: String) {
            if actual != expected { failures.append("\(what): got \(actual), expected \(expected)") }
        }
    }

    private static func check(_ name: String, _ body: (inout Expect) -> Void) -> Outcome {
        var expect = Expect()
        body(&expect)
        return Outcome(name: name, failures: expect.failures)
    }

    static let end = SonioxToken(text: SonioxToken.endMarker, isFinal: true, language: nil)

    static func original(_ text: String, _ language: String, final: Bool = true) -> SonioxToken {
        SonioxToken(text: text, isFinal: final, language: language, translationStatus: "original")
    }

    static func en(_ text: String) -> [SonioxToken] {
        CannedConversation.pieces(text).map { original($0, "en") }
    }

    static func zh(_ text: String) -> [SonioxToken] {
        CannedConversation.pieces(text).map { original($0, "zh") }
    }

    static func live(_ text: String, _ language: String) -> [SonioxToken] {
        CannedConversation.pieces(text).map { original($0, language, final: false) }
    }

    static func tr(_ text: String, from source: String, to target: String) -> [SonioxToken] {
        CannedConversation.pieces(text).map {
            SonioxToken(text: $0, isFinal: true, language: target, translationStatus: "translation", sourceLanguage: source)
        }
    }

    /// One line per case; true if all passed.
    static func report(_ outcomes: [Outcome], print line: (String) -> Void) -> Bool {
        for outcome in outcomes {
            line("\(outcome.passed ? "PASS" : "FAIL")  \(outcome.name)")
            for failure in outcome.failures { line("      \(failure)") }
        }
        let failed = outcomes.filter { !$0.passed }.count
        line("\(outcomes.count - failed)/\(outcomes.count) cases passed")
        return failed == 0
    }
}
#endif

#if TURN_RULE_CHECK_MAIN
@main
struct TurnRuleCheckMain {
    static func main() {
        let ok = TurnRuleCheck.report(TurnRuleCheck.runAll()) { print($0) }
        exit(ok ? 0 : 1)
    }
}
#endif
