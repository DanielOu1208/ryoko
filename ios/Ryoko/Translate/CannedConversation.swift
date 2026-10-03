import Foundation

/// Scripted Soniox responses for a short conversation, shaped like the real
/// stream: words arrive non-final and then final, `<end>` closes each
/// utterance, and translations follow (one of them late, after the next
/// speaker has started). Used by the DEBUG "canned" source (screenshots,
/// no microphone or key) and by the turn-rule harness. Foundation only.
nonisolated enum CannedConversation {
    /// One response and how long to wait before sending it.
    nonisolated struct Step: Sendable {
        var delay: TimeInterval
        var response: SonioxResponse
    }

    /// One utterance and its translation.
    nonisolated struct Line: Sendable {
        var speaker: TurnSpeaker
        var said: String
        var translated: String
    }

    /// The script for a pair: a tea shop in Chinese, a ramen shop in Japanese,
    /// or a short generic exchange for any other language.
    static func lines(for pair: TranslatePair) -> [Line] {
        switch pair.other.sonioxCode {
        case "ja":
            [
                Line(speaker: .me, said: "Hi, how does the ticket machine work?", translated: "すみません、券売機はどう使いますか？"),
                Line(speaker: .them, said: "ボタンを押して、お金を入れてください。", translated: "Press the button, then put the money in."),
                Line(speaker: .me, said: "Can I make it less salty?", translated: "味を薄めにできますか？"),
                Line(speaker: .them, said: "はい、食券を渡すときに言ってください。", translated: "Yes, tell us when you hand over the ticket."),
            ]
        default:
            [
                Line(speaker: .me, said: "Hi, could I get a jasmine milk tea, less sweet?", translated: "你好，我可以要一杯茉莉奶茶，少糖吗？"),
                Line(speaker: .them, said: "好的，要中杯还是大杯？", translated: "Sure, medium or large?"),
                Line(speaker: .me, said: "Medium, please. No ice.", translated: "中杯，谢谢。去冰。"),
                Line(speaker: .them, said: "一共十八块，扫码还是现金？", translated: "That's eighteen yuan. Scan to pay, or cash?"),
            ]
        }
    }

    /// The responses for `pair`'s script. The second line's translation
    /// arrives late, after the third line has started.
    static func steps(for pair: TranslatePair, pace: Double = 1) -> [Step] {
        let lines = lines(for: pair)
        var steps: [Step] = []
        var lateTranslation: [SonioxToken] = []
        for (index, line) in lines.enumerated() {
            let saidLanguage = line.speaker == .me ? pair.home.sonioxCode : pair.other.sonioxCode
            let translatedLanguage = line.speaker == .me ? pair.other.sonioxCode : pair.home.sonioxCode
            let said = pieces(line.said).map {
                SonioxToken(text: $0, isFinal: false, language: saidLanguage, translationStatus: "original")
            }
            let translated = pieces(line.translated).map {
                SonioxToken(
                    text: $0, isFinal: true, language: translatedLanguage,
                    translationStatus: "translation", sourceLanguage: saidLanguage
                )
            }
            let half = max(1, said.count / 2)
            let first = Array(said[..<half]), second = Array(said[half...])

            // Words appear live, then become final; `<end>` closes the utterance.
            steps.append(Step(delay: 1.0 * pace, response: SonioxResponse(tokens: first)))
            // The previous line's late translation shows up once this line has text.
            let firstStep = finals(first) + lateTranslation + second
            lateTranslation = []
            steps.append(Step(delay: 0.6 * pace, response: SonioxResponse(tokens: firstStep)))
            let end = SonioxToken(text: SonioxToken.endMarker, isFinal: true, language: nil)
            steps.append(Step(delay: 0.6 * pace, response: SonioxResponse(tokens: finals(second) + [end])))

            if index == 1 {
                lateTranslation = translated
            } else {
                let mid = max(1, translated.count / 2)
                let live = translated[..<mid].map { token -> SonioxToken in
                    var token = token
                    token.isFinal = false
                    return token
                }
                steps.append(Step(delay: 0.3 * pace, response: SonioxResponse(tokens: live)))
                steps.append(Step(delay: 0.4 * pace, response: SonioxResponse(tokens: translated)))
            }
        }
        if !lateTranslation.isEmpty {
            steps.append(Step(delay: 0.4 * pace, response: SonioxResponse(tokens: lateTranslation)))
        }
        return steps
    }

    private static func finals(_ tokens: [SonioxToken]) -> [SonioxToken] {
        tokens.map { token in
            var token = token
            token.isFinal = true
            return token
        }
    }

    /// Splits text roughly the way Soniox does: one token per CJK character,
    /// one per word (with its leading space) otherwise, punctuation on its own.
    static func pieces(_ text: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { pieces.append(current) }
            current = ""
        }
        for character in text {
            let string = String(character)
            if TurnRule.cjkCount(string) > 0 {
                flush()
                pieces.append(string)
            } else if character == " " {
                flush()
                current = " "
            } else if character.isPunctuation {
                flush()
                pieces.append(string)
            } else {
                current.append(character)
            }
        }
        flush()
        return pieces
    }
}
